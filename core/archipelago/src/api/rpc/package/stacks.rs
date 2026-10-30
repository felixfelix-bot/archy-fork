//! Multi-container app stack installers (Immich, Penpot, BTCPay, Mempool).
//!
//! Each stack pulls multiple images, creates a private network, and starts
//! containers in dependency order.

use crate::api::rpc::RpcHandler;
use crate::data_model::InstallPhase;
use anyhow::{Context, Result};
use std::process::Output;
use std::time::Duration;
use tracing::info;

use super::install::{install_log, patch_indeedhub_nostr_provider};

// 45s, not 10s: under heavy disk load (e.g. an ElectrumX resync/compaction
// hammering the same SSD) a plain `podman ps` was observed taking >10s on
// .116 (2026-07-22), failing a mempool install at the probe step for no real
// reason. Podman being slow is not podman being dead.
const PODMAN_STACK_PROBE_TIMEOUT: Duration = Duration::from_secs(45);
const PODMAN_STACK_LOG_TIMEOUT: Duration = Duration::from_secs(15);
const PODMAN_STACK_PULL_TIMEOUT: Duration = Duration::from_secs(600);
const PODMAN_STACK_REMOVE_TIMEOUT: Duration = Duration::from_secs(90);

async fn podman_stack_output(args: &[&str], timeout: Duration) -> Result<Output> {
    let mut cmd = tokio::process::Command::new("podman");
    cmd.args(args);
    cmd.kill_on_drop(true);
    tokio::time::timeout(timeout, cmd.output())
        .await
        .with_context(|| {
            format!(
                "podman {} timed out after {}s",
                args.join(" "),
                timeout.as_secs()
            )
        })?
        .with_context(|| format!("failed to run podman {}", args.join(" ")))
}

async fn podman_stack_status(args: &[&str], timeout: Duration) -> Result<std::process::ExitStatus> {
    let mut cmd = tokio::process::Command::new("podman");
    cmd.args(args);
    cmd.kill_on_drop(true);
    tokio::time::timeout(timeout, cmd.status())
        .await
        .with_context(|| {
            format!(
                "podman {} timed out after {}s",
                args.join(" "),
                timeout.as_secs()
            )
        })?
        .with_context(|| format!("failed to run podman {}", args.join(" ")))
}

async fn force_remove_stack_container(container_name: &str) -> Result<()> {
    for args in [
        vec!["rm", "-f", container_name],
        vec!["rm", "-f", "--time", "0", container_name],
    ] {
        let output = podman_stack_output(&args, PODMAN_STACK_REMOVE_TIMEOUT).await?;
        if output.status.success()
            || is_missing_container_error(&String::from_utf8_lossy(&output.stderr))
        {
            return wait_for_stack_container_absent(container_name, Duration::from_secs(90)).await;
        }
    }

    let _ = podman_stack_output(
        &["container", "cleanup", container_name],
        PODMAN_STACK_PROBE_TIMEOUT,
    )
    .await;
    let output =
        podman_stack_output(&["rm", "-f", container_name], PODMAN_STACK_REMOVE_TIMEOUT).await?;
    if output.status.success()
        || is_missing_container_error(&String::from_utf8_lossy(&output.stderr))
    {
        return wait_for_stack_container_absent(container_name, Duration::from_secs(90)).await;
    }

    Err(anyhow::anyhow!(
        "force remove {} failed: {}",
        container_name,
        String::from_utf8_lossy(&output.stderr).trim()
    ))
}

async fn wait_for_stack_container_absent(container_name: &str, timeout: Duration) -> Result<()> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        let output = match podman_stack_output(
            &["ps", "-a", "--format", "{{.Names}}"],
            PODMAN_STACK_REMOVE_TIMEOUT,
        )
        .await
        {
            Ok(output) => output,
            Err(e) if std::time::Instant::now() < deadline => {
                tracing::warn!(
                    container = %container_name,
                    error = %e,
                    "inspect during stack removal wait failed; retrying"
                );
                tokio::time::sleep(Duration::from_secs(2)).await;
                continue;
            }
            Err(e) => return Err(e),
        };
        if output.status.success()
            && !String::from_utf8_lossy(&output.stdout)
                .lines()
                .any(|line| line.trim() == container_name)
        {
            return Ok(());
        }

        if std::time::Instant::now() >= deadline {
            let state = format!(
                "stdout={} stderr={}",
                String::from_utf8_lossy(&output.stdout).trim(),
                String::from_utf8_lossy(&output.stderr).trim()
            );
            return Err(anyhow::anyhow!(
                "container {} still exists after removal attempt: {}",
                container_name,
                state
            ));
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

fn is_missing_container_error(stderr: &str) -> bool {
    stderr.contains("no such container")
        || stderr.contains("no container with name")
        // podman 5.x `inspect` phrasing: `Error: no such object: "name"`
        || stderr.contains("no such object")
        || stderr.contains("does not exist")
        || stderr.contains("not found")
}

/// Adopt an existing container stack: start all named containers and return success.
/// Returns `Ok(Some(json))` if the primary container was found (adopted),
/// or `Ok(None)` if it was not found (proceed with fresh install).
async fn adopt_stack_if_exists(
    primary_container: &str,
    stack_name: &str,
    all_containers: &[&str],
) -> Result<Option<serde_json::Value>> {
    let check = podman_stack_output(
        &["ps", "-a", "--format", "{{.Names}}"],
        PODMAN_STACK_PROBE_TIMEOUT,
    )
    .await
    .context("Failed to list containers")?;
    let stdout = String::from_utf8_lossy(&check.stdout);
    let names: Vec<&str> = stdout.lines().map(|l| l.trim()).collect();

    if !names.contains(&primary_container) {
        return Ok(None);
    }

    info!(
        "{} stack already exists (found {}), adopting",
        stack_name, primary_container
    );
    install_log(&format!(
        "INSTALL ADOPT: {} — stack already exists",
        stack_name
    ))
    .await;

    repair_stack_before_adopt(stack_name).await;

    for container in all_containers {
        if names.iter().any(|n| n == container) {
            let _ =
                podman_stack_output(["start", container].as_slice(), PODMAN_STACK_PROBE_TIMEOUT)
                    .await;
        }
    }
    let existing: Vec<&str> = all_containers
        .iter()
        .copied()
        .filter(|container| names.iter().any(|n| n == container))
        .collect();
    wait_for_stack_containers(stack_name, &existing, 60).await?;

    if stack_name == "indeedhub" {
        patch_indeedhub_nostr_provider().await;
    }

    install_log(&format!(
        "INSTALL ADOPT OK: {} — started existing containers",
        stack_name
    ))
    .await;
    Ok(Some(serde_json::json!({
        "success": true,
        "package_id": stack_name,
        "message": format!("{} already installed and running", stack_name)
    })))
}

async fn repair_stack_before_adopt(stack_name: &str) {
    match stack_name {
        "btcpay" | "btcpay-server" => {
            let _ = tokio::process::Command::new("sudo")
                .args([
                    "mkdir",
                    "-p",
                    "/var/lib/archipelago/btcpay/Main",
                    "/var/lib/archipelago/nbxplorer/Main",
                ])
                .output()
                .await;
            let user = std::env::var("USER").unwrap_or_else(|_| "archipelago".to_string());
            for dir in [
                "/var/lib/archipelago/btcpay",
                "/var/lib/archipelago/nbxplorer",
            ] {
                let _ = tokio::process::Command::new("sudo")
                    .args(["chown", "-R", &format!("{}:{}", user, user), dir])
                    .output()
                    .await;
            }
        }
        "indeedhub" => repair_indeedhub_network_aliases().await,
        "netbird" => repair_netbird_network_aliases().await,
        _ => {}
    }
}

pub(in crate::api::rpc::package) async fn repair_indeedhub_network_aliases() {
    let _ = podman_stack_output(
        &["network", "create", "indeedhub-net"],
        PODMAN_STACK_PROBE_TIMEOUT,
    )
    .await;

    for (container, alias) in [
        ("indeedhub-postgres", "postgres"),
        ("indeedhub-redis", "redis"),
        ("indeedhub-minio", "minio"),
        ("indeedhub-relay", "relay"),
        ("indeedhub-api", "api"),
        ("indeedhub", "indeedhub"),
    ] {
        let exists = podman_stack_status(
            &["container", "exists", container],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await
        .map(|s| s.success())
        .unwrap_or(false);
        if !exists {
            continue;
        }
        if indeedhub_alias_present(container, alias).await {
            continue;
        }

        let _ = podman_stack_output(
            &["network", "disconnect", "-f", "indeedhub-net", container],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;
        let _ = podman_stack_output(
            &[
                "network",
                "connect",
                "--alias",
                alias,
                "indeedhub-net",
                container,
            ],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;
    }
}

async fn indeedhub_alias_present(container: &str, alias: &str) -> bool {
    network_alias_present("indeedhub-net", container, alias).await
}

async fn network_alias_present(network_name: &str, container: &str, alias: &str) -> bool {
    let output = match podman_stack_output(
        &[
            "inspect",
            container,
            "--format",
            "{{json .NetworkSettings.Networks}}",
        ],
        PODMAN_STACK_PROBE_TIMEOUT,
    )
    .await
    {
        Ok(output) if output.status.success() => output,
        _ => return false,
    };

    let Ok(networks) = serde_json::from_slice::<serde_json::Value>(&output.stdout) else {
        return false;
    };
    networks
        .get(network_name)
        .and_then(|network| network.get("Aliases"))
        .and_then(|aliases| aliases.as_array())
        .map(|aliases| aliases.iter().any(|value| value.as_str() == Some(alias)))
        .unwrap_or(false)
}

pub(in crate::api::rpc::package) async fn repair_netbird_network_aliases() {
    let _ = podman_stack_output(
        &["network", "create", "netbird-net"],
        PODMAN_STACK_PROBE_TIMEOUT,
    )
    .await;

    for (container, alias) in [
        ("netbird-server", "netbird-server"),
        ("netbird-dashboard", "netbird-dashboard"),
        ("netbird", "netbird"),
    ] {
        let exists = podman_stack_status(
            &["container", "exists", container],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await
        .map(|s| s.success())
        .unwrap_or(false);
        if !exists {
            continue;
        }
        if network_alias_present("netbird-net", container, alias).await {
            continue;
        }

        let _ = podman_stack_output(
            &["network", "disconnect", "-f", "netbird-net", container],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;
        let _ = podman_stack_output(
            &[
                "network",
                "connect",
                "--alias",
                alias,
                "netbird-net",
                container,
            ],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;
    }
}

async fn run_required_stack_command(
    stack_name: &str,
    label: &str,
    cmd: &mut tokio::process::Command,
) -> Result<()> {
    let output = cmd
        .output()
        .await
        .with_context(|| format!("{}: failed to run {}", stack_name, label))?;
    if output.status.success() {
        return Ok(());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let msg = format!("{} failed: {}{}", label, stdout, stderr);
    install_log(&format!("INSTALL FAIL: {} - {}", stack_name, msg.trim())).await;
    Err(anyhow::anyhow!("{} {}", stack_name, msg.trim()))
}

async fn run_required_scoped_podman_stack_command(
    stack_name: &str,
    label: &str,
    args: Vec<String>,
) -> Result<()> {
    run_required_scoped_podman_stack_command_with_env(stack_name, label, args, &[]).await
}

async fn run_required_scoped_podman_stack_command_with_env(
    stack_name: &str,
    label: &str,
    args: Vec<String>,
    env: &[String],
) -> Result<()> {
    let mut cmd = tokio::process::Command::new("systemd-run");
    cmd.args(["--user", "--scope", "--quiet", "--collect"]);
    for item in env {
        cmd.arg(format!("--setenv={item}"));
    }
    cmd.arg("podman");
    cmd.args(&args);
    let output = cmd
        .output()
        .await
        .with_context(|| format!("{}: failed to run scoped {}", stack_name, label))?;
    if output.status.success() {
        return Ok(());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if matches!(args.first().map(String::as_str), Some("run" | "create")) {
        let msg = format!("{} scoped creation failed: {}{}", label, stdout, stderr);
        install_log(&format!("INSTALL FAIL: {} - {}", stack_name, msg.trim())).await;
        return Err(anyhow::anyhow!("{} {}", stack_name, msg.trim()));
    }

    install_log(&format!(
        "INSTALL WARN: {} - scoped {} failed: {}{}; trying direct podman",
        stack_name, label, stdout, stderr
    ))
    .await;

    let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
    let direct = podman_stack_output(&refs, PODMAN_STACK_PULL_TIMEOUT).await?;
    if direct.status.success() {
        return Ok(());
    }

    let stdout = String::from_utf8_lossy(&direct.stdout);
    let stderr = String::from_utf8_lossy(&direct.stderr);
    let msg = format!("{} failed: {}{}", label, stdout, stderr);
    install_log(&format!("INSTALL FAIL: {} - {}", stack_name, msg.trim())).await;
    Err(anyhow::anyhow!("{} {}", stack_name, msg.trim()))
}

async fn wait_for_stack_containers(
    stack_name: &str,
    containers: &[&str],
    timeout_secs: u64,
) -> Result<()> {
    // A container can exit on its first start because a dependency (db, redis,
    // the bitcoin node) was not quite ready — a transient crash, not a broken
    // install. Restart each exited container a bounded number of times before
    // declaring the install failed (#25). The runtime supervisor keeps it alive
    // afterwards, but we want a healthy state by the time install returns.
    const MAX_RESTARTS: u32 = 3;
    let mut restarts: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);
    loop {
        let mut pending = Vec::new();
        for container in containers {
            let status = podman_stack_output(
                &["inspect", container, "--format", "{{.State.Status}}"],
                PODMAN_STACK_PROBE_TIMEOUT,
            )
            .await;
            match status {
                Ok(output) if output.status.success() => {
                    let state = String::from_utf8_lossy(&output.stdout).trim().to_string();
                    match state.as_str() {
                        "running" => {}
                        "exited" | "dead" => {
                            let attempts = restarts.entry(container.to_string()).or_insert(0);
                            if *attempts < MAX_RESTARTS {
                                *attempts += 1;
                                install_log(&format!(
                                    "INSTALL RESTART: {} - container {} exited, restart attempt {}/{}",
                                    stack_name, container, *attempts, MAX_RESTARTS
                                ))
                                .await;
                                let _ = podman_stack_output(
                                    &["start", container],
                                    PODMAN_STACK_PROBE_TIMEOUT,
                                )
                                .await;
                                pending.push(format!(
                                    "{}=restarting({}/{})",
                                    container, *attempts, MAX_RESTARTS
                                ));
                            } else {
                                let logs = stack_container_logs(container, 40).await;
                                install_log(&format!(
                                    "INSTALL CRASH: {} - container {} exited after {} restarts. Logs:\n{}",
                                    stack_name,
                                    container,
                                    MAX_RESTARTS,
                                    logs.chars().take(1000).collect::<String>()
                                ))
                                .await;
                                return Err(anyhow::anyhow!(
                                    "{} container {} exited after install ({} restarts). Logs: {}",
                                    stack_name,
                                    container,
                                    MAX_RESTARTS,
                                    logs.chars().take(500).collect::<String>()
                                ));
                            }
                        }
                        other => pending.push(format!("{}={}", container, other)),
                    }
                }
                Ok(output) => {
                    pending.push(format!(
                        "{}=missing({})",
                        container,
                        String::from_utf8_lossy(&output.stderr).trim()
                    ));
                }
                Err(e) => pending.push(format!("{}=inspect-error({})", container, e)),
            }
        }

        if pending.is_empty() {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            install_log(&format!(
                "INSTALL TIMEOUT: {} - containers not running: {}",
                stack_name,
                pending.join(", ")
            ))
            .await;
            return Err(anyhow::anyhow!(
                "{} containers did not reach running state: {}",
                stack_name,
                pending.join(", ")
            ));
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}

async fn wait_for_stack_container_health(
    stack_name: &str,
    container: &str,
    timeout_secs: u64,
) -> Result<()> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);
    loop {
        let status = podman_stack_output(
            &[
                "inspect",
                container,
                "--format",
                "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}",
            ],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;
        match status {
            Ok(output) if output.status.success() => {
                let health = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if health == "healthy" {
                    return Ok(());
                }
                if health == "unhealthy" {
                    let logs = stack_container_logs(container, 80).await;
                    install_log(&format!(
                        "INSTALL UNHEALTHY: {} - container {} unhealthy. Logs:\n{}",
                        stack_name,
                        container,
                        logs.chars().take(1000).collect::<String>()
                    ))
                    .await;
                }
            }
            Ok(output) => {
                install_log(&format!(
                    "INSTALL HEALTH WAIT: {} - {} inspect failed: {}",
                    stack_name,
                    container,
                    String::from_utf8_lossy(&output.stderr).trim()
                ))
                .await;
            }
            Err(e) => {
                install_log(&format!(
                    "INSTALL HEALTH WAIT: {} - {} inspect error: {}",
                    stack_name, container, e
                ))
                .await;
            }
        }

        if std::time::Instant::now() >= deadline {
            return Err(anyhow::anyhow!(
                "{} container {} did not become healthy within {}s",
                stack_name,
                container,
                timeout_secs
            ));
        }
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    }
}

async fn stack_container_logs(container: &str, lines: u32) -> String {
    podman_stack_output(
        &["logs", "--tail", &lines.to_string(), container],
        PODMAN_STACK_LOG_TIMEOUT,
    )
    .await
    .map(|o| {
        let stdout = String::from_utf8_lossy(&o.stdout);
        let stderr = String::from_utf8_lossy(&o.stderr);
        format!("{}{}", stdout, stderr)
    })
    .unwrap_or_default()
}

async fn install_stack_via_orchestrator(
    handler: &RpcHandler,
    stack_name: &str,
    app_ids: &[&str],
) -> Result<Option<serde_json::Value>> {
    let Some(orchestrator) = handler.orchestrator.as_ref() else {
        return Ok(None);
    };

    install_log(&format!(
        "INSTALL ORCH: {} stack — attempting orchestrator install of [{}]",
        stack_name,
        app_ids.join(", ")
    ))
    .await;

    // Phase: PullingImage — each member's orchestrator.install covers its
    // whole pipeline (pull + create + start + health wait), and on a fresh
    // node the pull dominates wall-clock. The X-of-N counter below is what
    // the UI interpolates across the PullingImage band (20→70%); without
    // these updates an orchestrator-installed stack sat at "Preparing… 5%"
    // for the entire multi-gigabyte pull (indeedhub: 7 images).
    let total = app_ids.len() as u64;
    handler
        .set_install_phase(stack_name, InstallPhase::PullingImage)
        .await;

    let mut installed = 0usize;
    for (idx, app_id) in app_ids.iter().enumerate() {
        handler
            .set_install_progress(stack_name, idx as u64, total)
            .await;
        // Message after progress: set_install_progress resets the label,
        // set_install_message preserves the phase + counters just written.
        let component = app_id
            .strip_prefix(&format!("{stack_name}-"))
            .unwrap_or(app_id);
        handler
            .set_install_message(
                stack_name,
                &format!("Installing {} ({} of {})…", component, idx + 1, total),
            )
            .await;
        match orchestrator.install(app_id).await {
            Ok(container_name) => {
                installed += 1;
                install_log(&format!(
                    "INSTALL ORCH: {} stack — app {} installed as {}",
                    stack_name, app_id, container_name
                ))
                .await;
            }
            Err(e) if e.to_string().contains("unknown app_id") && installed == 0 => {
                // None of the stack's manifests are known — the orchestrator
                // can't render this stack at all, so defer to the legacy
                // installer. Only safe when NOTHING was installed yet: once an
                // earlier member is up, falling back would let the legacy path
                // double-create containers on the same data dir (observed
                // corrupting an immich postgres cluster — two postmasters, one
                // PGDATA). A partial set means a deploy bug, not a legacy node.
                install_log(&format!(
                    "INSTALL ORCH SKIP: {} stack — app {} unknown, falling back to legacy stack installer",
                    stack_name, app_id
                ))
                .await;
                return Ok(None);
            }
            Err(e) if e.to_string().contains("unknown app_id") => {
                install_log(&format!(
                    "INSTALL ORCH FAIL: {} stack — app {} unknown AFTER {} installed; refusing legacy fallback (would double-create on shared data)",
                    stack_name, app_id, installed
                ))
                .await;
                return Err(e.context(format!(
                    "orchestrator stack install {} aborted: app {} has no manifest but {} member(s) already installed — deploy all stack manifests",
                    stack_name, app_id, installed
                )));
            }
            Err(e) => {
                install_log(&format!(
                    "INSTALL ORCH FAIL: {} stack — app {} failed: {}",
                    stack_name, app_id, e
                ))
                .await;
                return Err(e.context(format!(
                    "orchestrator stack install {} failed at app {}",
                    stack_name, app_id
                )));
            }
        }
    }

    // Truthful end-of-install signal, mirroring the legacy stack installers:
    // the real readiness gate is the scanner's next sweep, this just settles
    // the bar at 95→100→done instead of leaving it mid-band.
    handler.set_install_progress(stack_name, total, total).await;
    handler
        .set_install_phase(stack_name, InstallPhase::PostInstall)
        .await;
    handler
        .set_install_phase(stack_name, InstallPhase::Done)
        .await;
    handler.clear_install_progress(stack_name).await;

    install_log(&format!("INSTALL ORCH OK: {} stack", stack_name)).await;
    Ok(Some(serde_json::json!({
        "success": true,
        "package_id": stack_name,
        "message": format!("{} stack installed and started", stack_name),
        "path": "orchestrator"
    })))
}

fn btcpay_stack_app_ids() -> &'static [&'static str] {
    &["archy-btcpay-db", "archy-nbxplorer", "btcpay-server"]
}

fn mempool_stack_app_ids() -> &'static [&'static str] {
    &["archy-mempool-db", "mempool-api", "archy-mempool-web"]
}

fn immich_stack_app_ids() -> &'static [&'static str] {
    // Install order = dependency order: db + cache before the server. The server
    // app_id is the user-facing "immich" (canonical name + icon); its install is
    // handled here (not recursively) since orchestrator.install bypasses the
    // package.install routing that maps "immich" → this stack installer.
    &["immich-postgres", "immich-redis", "immich"]
}

fn netbird_stack_app_ids() -> &'static [&'static str] {
    // Dependency/startup order: the combined management/signal/relay server
    // first (it owns the base64 relay/store secrets + the sqlite store, and is
    // the OIDC issuer the others point at), then the dashboard SPA, then the
    // user-facing TLS proxy ("netbird", which carries the self-signed cert +
    // the templated nginx.conf and is the launcher). Mirrors the netbird
    // startup_order in dependencies.rs.
    &["netbird-server", "netbird-dashboard", "netbird"]
}

fn pine_stack_app_ids() -> &'static [&'static str] {
    // Dependency/startup order: the two Wyoming engines (STT + TTS) first — they
    // own their downloaded model/voice under /data and publish 10300/10200 —
    // then the user-facing launcher ("pine", the nginx that serves the setup /
    // status page + is the Open target). Mirrors the pine startup_order in
    // dependencies.rs + the stack member table in app_ops.rs.
    &["pine-whisper", "pine-piper", "pine-openwakeword", "pine"]
}

fn indeedhub_stack_app_ids() -> &'static [&'static str] {
    // Dependency order: backends + their generated secrets first, then the api
    // (owns indeedhub-jwt; reads the db/minio secrets the backends materialised),
    // then the ffmpeg worker, then the user-facing frontend ("indeedhub", which
    // carries the post_install nginx hook). The frontend's nginx reaches the
    // backends by their short network_aliases (api/minio/relay) on indeedhub-net.
    &[
        "indeedhub-postgres",
        "indeedhub-redis",
        "indeedhub-minio",
        "indeedhub-relay",
        "indeedhub-api",
        "indeedhub-ffmpeg",
        "indeedhub",
    ]
}

const REGISTRY: &str = "source.archipelago-foundation.org/lfg2025";

/// Pull an image with retry and exponential backoff (3 attempts).
async fn pull_image_with_retry(image: &str) -> Result<()> {
    let exists = podman_stack_status(&["image", "exists", image], PODMAN_STACK_PROBE_TIMEOUT).await;
    if matches!(exists, Ok(status) if status.success()) {
        return Ok(());
    }

    const MAX_ATTEMPTS: u32 = 3;
    const BACKOFF_SECS: [u64; 3] = [5, 15, 45];

    for attempt in 1..=MAX_ATTEMPTS {
        let mut cmd = tokio::process::Command::new("podman");
        cmd.arg("pull");
        if archipelago_container::image_uses_insecure_registry(image) {
            cmd.arg("--tls-verify=false");
        }
        cmd.arg(image);
        cmd.kill_on_drop(true);
        let output = tokio::time::timeout(PODMAN_STACK_PULL_TIMEOUT, cmd.output())
            .await
            .with_context(|| {
                format!(
                    "podman pull {image} timed out after {}s",
                    PODMAN_STACK_PULL_TIMEOUT.as_secs()
                )
            })?
            .context("Failed to execute podman pull")?;

        if output.status.success() {
            return Ok(());
        }

        if attempt < MAX_ATTEMPTS {
            let delay = BACKOFF_SECS[(attempt - 1) as usize];
            let stderr = String::from_utf8_lossy(&output.stderr);
            tracing::warn!(
                "Image pull failed for {} (attempt {}/{}): {}. Retrying in {}s...",
                image,
                attempt,
                MAX_ATTEMPTS,
                stderr.trim(),
                delay
            );
            tokio::time::sleep(std::time::Duration::from_secs(delay)).await;
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!(
                "Failed to pull {} after {} attempts: {}",
                image,
                MAX_ATTEMPTS,
                stderr.trim()
            ));
        }
    }
    unreachable!()
}

impl RpcHandler {
    /// Install Immich stack (postgres + redis + server).
    pub(super) async fn install_immich_stack(&self) -> Result<serde_json::Value> {
        // Manifest-driven path (workstream B/C): render the stack from
        // apps/immich-*/manifest.yml via the orchestrator (rootless Quadlet
        // units, generated_secrets, reboot-survivable). Falls back to the legacy
        // installer below only when the orchestrator doesn't know these app_ids
        // (manifests not yet deployed). See docs/PRODUCTION-MASTER-PLAN.md.
        if let Some(orchestrated) =
            install_stack_via_orchestrator(self, "immich", immich_stack_app_ids()).await?
        {
            return Ok(orchestrated);
        }

        if let Some(adopted) = adopt_stack_if_exists(
            "immich_server",
            "immich",
            &["immich_postgres", "immich_redis", "immich_server"],
        )
        .await?
        {
            return Ok(adopted);
        }

        // Clean up stale "immich" container (old naming) before fresh install
        let check = podman_stack_output(
            &["ps", "-a", "--format", "{{.Names}}"],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await
        .context("Failed to list containers")?;
        let stdout = String::from_utf8_lossy(&check.stdout);
        if stdout.contains("immich\n") || stdout.lines().any(|l| l.trim() == "immich") {
            let _ = podman_stack_output(&["stop", "immich"], PODMAN_STACK_PROBE_TIMEOUT).await;
            let _ = force_remove_stack_container("immich").await;
        }

        let images = [
            "source.archipelago-foundation.org/lfg2025/immich-postgres:14-vectorchord0.4.3-pgvectors0.2.0",
            "source.archipelago-foundation.org/lfg2025/valkey:7-alpine",
            "source.archipelago-foundation.org/lfg2025/immich-server:release",
        ];
        self.set_install_phase("immich", InstallPhase::PullingImage)
            .await;
        let n_images = images.len() as u64;
        for (i, img) in images.iter().enumerate() {
            self.set_install_progress("immich", i as u64, n_images)
                .await;
            pull_image_with_retry(img).await?;
        }
        self.set_install_progress("immich", n_images, n_images)
            .await;
        self.set_install_phase("immich", InstallPhase::CreatingContainer)
            .await;

        let _ = tokio::process::Command::new("sudo")
            .args([
                "mkdir",
                "-p",
                "/var/lib/archipelago/immich",
                "/var/lib/archipelago/immich-db",
            ])
            .output()
            .await;
        let _ = tokio::process::Command::new("sudo")
            .args([
                "chown",
                "-R",
                "1000:1000",
                "/var/lib/archipelago/immich",
                "/var/lib/archipelago/immich-db",
            ])
            .output()
            .await;
        let _ = podman_stack_output(
            &["network", "create", "immich-net"],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;

        let db_pass = super::config::read_or_generate_secret("immich-db-password").await;

        let mut postgres_cmd = tokio::process::Command::new("podman");
        postgres_cmd.args([
            "run",
            "-d",
            "--name",
            "immich_postgres",
            "--restart",
            "unless-stopped",
            "--network",
            "immich-net",
            "--network-alias",
            "immich_postgres",
            "--cap-drop=ALL",
            "--cap-add=CHOWN",
            "--cap-add=DAC_OVERRIDE",
            "--cap-add=FOWNER",
            "--cap-add=SETGID",
            "--cap-add=SETUID",
            "--security-opt=no-new-privileges:true",
            "--memory=2g",
            "--pids-limit=4096",
            "--health-cmd=pg_isready -U postgres || exit 1",
            "--health-interval=30s",
            "--health-retries=3",
            "-v",
            "/var/lib/archipelago/immich-db:/var/lib/postgresql/data",
            "-e",
            &format!("POSTGRES_PASSWORD={}", db_pass),
            "-e",
            "POSTGRES_USER=postgres",
            "-e",
            "POSTGRES_DB=immich",
            "source.archipelago-foundation.org/lfg2025/immich-postgres:14-vectorchord0.4.3-pgvectors0.2.0",
        ]);
        run_required_stack_command("immich", "create postgres", &mut postgres_cmd).await?;
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;

        let mut redis_cmd = tokio::process::Command::new("podman");
        redis_cmd.args([
            "run",
            "-d",
            "--name",
            "immich_redis",
            "--restart",
            "unless-stopped",
            "--network",
            "immich-net",
            "--network-alias",
            "immich_redis",
            "--cap-drop=ALL",
            "--cap-add=SETGID",
            "--cap-add=SETUID",
            "--security-opt=no-new-privileges:true",
            "--memory=128m",
            "--pids-limit=2048",
            "--health-cmd=valkey-cli ping || exit 1",
            "--health-interval=30s",
            "--health-retries=3",
            "source.archipelago-foundation.org/lfg2025/valkey:7-alpine",
        ]);
        run_required_stack_command("immich", "create redis", &mut redis_cmd).await?;
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;

        run_required_scoped_podman_stack_command(
            "immich",
            "create server",
            vec![
                "run".to_string(),
                "-d".to_string(),
                "--name".to_string(),
                "immich_server".to_string(),
                "--restart".to_string(),
                "unless-stopped".to_string(),
                "--network".to_string(),
                "immich-net".to_string(),
                "--network-alias".to_string(),
                "immich_server".to_string(),
                "--cap-drop=ALL".to_string(),
                "--security-opt=no-new-privileges:true".to_string(),
                "--memory=2g".to_string(),
                "--pids-limit=4096".to_string(),
                "--health-cmd=curl -sf http://localhost:2283/api/server/ping || exit 1".to_string(),
                "--health-interval=30s".to_string(),
                "--health-retries=20".to_string(),
                "--health-start-period=180s".to_string(),
                "-p".to_string(),
                "2283:2283".to_string(),
                "-v".to_string(),
                "/var/lib/archipelago/immich:/usr/src/app/upload".to_string(),
                "-e".to_string(),
                "DB_HOSTNAME=immich_postgres".to_string(),
                "-e".to_string(),
                "DB_USERNAME=postgres".to_string(),
                "-e".to_string(),
                format!("DB_PASSWORD={}", db_pass),
                "-e".to_string(),
                "DB_DATABASE_NAME=immich".to_string(),
                "-e".to_string(),
                "REDIS_HOSTNAME=immich_redis".to_string(),
                "-e".to_string(),
                "UPLOAD_LOCATION=/usr/src/app/upload".to_string(),
                "source.archipelago-foundation.org/lfg2025/immich-server:release".to_string(),
            ],
        )
        .await?;

        self.set_install_phase("immich", InstallPhase::WaitingHealthy)
            .await;
        wait_for_stack_containers(
            "immich",
            &["immich_postgres", "immich_redis", "immich_server"],
            120,
        )
        .await?;
        wait_for_stack_container_health("immich", "immich_server", 360).await?;
        self.set_install_phase("immich", InstallPhase::PostInstall)
            .await;
        self.set_install_phase("immich", InstallPhase::Done).await;
        self.clear_install_progress("immich").await;

        info!("Immich stack installed and started");
        Ok(serde_json::json!({
            "success": true,
            "package_id": "immich",
            "message": "Immich stack installed and started"
        }))
    }

    /// Install BTCPay stack (postgres + nbxplorer + btcpay-server).
    pub(super) async fn install_btcpay_stack(&self) -> Result<serde_json::Value> {
        if let Some(orchestrated) =
            install_stack_via_orchestrator(self, "btcpay-server", btcpay_stack_app_ids()).await?
        {
            return Ok(orchestrated);
        }

        if let Some(adopted) = adopt_stack_if_exists(
            "btcpay-server",
            "btcpay",
            &["archy-btcpay-db", "archy-nbxplorer", "btcpay-server"],
        )
        .await?
        {
            return Ok(adopted);
        }

        // Dependency check: Bitcoin must be running. Bounded wait covers the
        // "installed but still starting" race instead of failing instantly.
        self.gate_install_deps("btcpay-server").await?;

        install_log("INSTALL START: btcpay-server (stack: postgres + nbxplorer + btcpay)").await;

        let (rpc_user, rpc_pass) = crate::bitcoin_rpc::bitcoin_rpc_credentials().await;
        let host_ip = &self.config.host_ip;

        // Read or generate btcpay DB password
        let db_pass = super::config::read_or_generate_secret("btcpay-db-password").await;

        let images = [
            &format!("{}/postgres:15.17", REGISTRY),
            &format!("{}/nbxplorer:2.6.0", REGISTRY),
            "docker.io/btcpayserver/btcpayserver:2.4.3",
        ];
        self.set_install_phase("btcpay-server", InstallPhase::PullingImage)
            .await;
        let n_images = images.len() as u64;
        for (i, img) in images.iter().enumerate() {
            self.set_install_progress("btcpay-server", i as u64, n_images)
                .await;
            pull_image_with_retry(img).await?;
        }
        self.set_install_progress("btcpay-server", n_images, n_images)
            .await;
        self.set_install_phase("btcpay-server", InstallPhase::CreatingContainer)
            .await;

        // Create data dirs (chown to current user so rootless podman can write)
        let _ = tokio::process::Command::new("sudo")
            .args([
                "mkdir",
                "-p",
                "/var/lib/archipelago/postgres-btcpay",
                "/var/lib/archipelago/btcpay/Main",
                "/var/lib/archipelago/nbxplorer/Main",
            ])
            .output()
            .await;
        let user = std::env::var("USER").unwrap_or_else(|_| "archipelago".to_string());
        for dir in &[
            "/var/lib/archipelago/postgres-btcpay",
            "/var/lib/archipelago/btcpay",
            "/var/lib/archipelago/nbxplorer",
        ] {
            let _ = tokio::process::Command::new("sudo")
                .args(["chown", "-R", &format!("{}:{}", user, user), dir])
                .output()
                .await;
        }

        // Ensure archy-net exists
        let _ = podman_stack_output(
            &["network", "create", "archy-net"],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;

        // 1. PostgreSQL
        let _ = tokio::process::Command::new("podman")
            .args([
                "run",
                "-d",
                "--name",
                "archy-btcpay-db",
                "--restart",
                "unless-stopped",
                "--network",
                "archy-net",
                "--network-alias",
                "archy-btcpay-db",
                "--cap-drop=ALL",
                "--cap-add=CHOWN",
                "--cap-add=DAC_OVERRIDE",
                "--cap-add=FOWNER",
                "--cap-add=SETGID",
                "--cap-add=SETUID",
                "--security-opt=no-new-privileges:true",
                "--memory=512m",
                "--pids-limit=4096",
                "--health-cmd=pg_isready -U btcpay || exit 1",
                "--health-interval=30s",
                "--health-retries=3",
                "-v",
                "/var/lib/archipelago/postgres-btcpay:/var/lib/postgresql/data",
                "-e",
                "POSTGRES_DB=btcpay",
                "-e",
                "POSTGRES_USER=btcpay",
                "-e",
                &format!("POSTGRES_PASSWORD={}", db_pass),
                &format!("{}/postgres:15.17", REGISTRY),
            ])
            .output()
            .await;
        tokio::time::sleep(std::time::Duration::from_secs(8)).await;

        // Create nbxplorer database (superuser is "btcpay", not "postgres")
        let _ = tokio::process::Command::new("podman")
            .args([
                "exec",
                "archy-btcpay-db",
                "psql",
                "-U",
                "btcpay",
                "-c",
                "CREATE DATABASE nbxplorer;",
            ])
            .output()
            .await;

        // 2. NBXplorer
        let _ = tokio::process::Command::new("podman")
            .args([
                "run", "-d",
                "--name", "archy-nbxplorer",
                "--restart", "unless-stopped",
                "--network", "archy-net",
                "--network-alias", "archy-nbxplorer",
                "--cap-drop=ALL",
                "--security-opt=no-new-privileges:true",
                "--memory=512m",
                "--pids-limit=4096",
                "-p", "32838:32838",
                "-v", "/var/lib/archipelago/nbxplorer:/data",
                "-e", "NBXPLORER_DATADIR=/data",
                "-e", "NBXPLORER_NETWORK=mainnet",
                "-e", "NBXPLORER_CHAINS=btc",
                "-e", "NBXPLORER_BIND=0.0.0.0:32838",
                "-e", "NBXPLORER_BTCRPCURL=http://host.containers.internal:8332",
                "-e", &format!("NBXPLORER_BTCRPCUSER={}", rpc_user),
                "-e", &format!("NBXPLORER_BTCRPCPASSWORD={}", rpc_pass),
                "-e", "NBXPLORER_BTCNODEENDPOINT=host.containers.internal:8333",
                "-e", "NBXPLORER_NOAUTH=1",
                "-e", &format!(
                    "NBXPLORER_POSTGRES=User ID=btcpay;Password={};Host=archy-btcpay-db;Port=5432;Database=nbxplorer;Include Error Detail=true",
                    db_pass
                ),
                &format!("{}/nbxplorer:2.6.0", REGISTRY),
            ])
            .output()
            .await;
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;

        // 3. BTCPay Server
        let run = tokio::process::Command::new("podman")
            .args([
                "run", "-d",
                "--name", "btcpay-server",
                "--restart", "unless-stopped",
                "--network", "archy-net",
                "--network-alias", "btcpay-server",
                "--cap-drop=ALL",
                "--security-opt=no-new-privileges:true",
                "--memory=1g",
                "--pids-limit=4096",
                "-p", "23000:49392",
                "-v", "/var/lib/archipelago/btcpay:/datadir",
                "-e", "ASPNETCORE_URLS=http://0.0.0.0:49392",
                "-e", "BTCPAY_PROTOCOL=http",
                "-e", &format!("BTCPAY_HOST={}:23000", host_ip),
                "-e", "BTCPAY_CHAINS=btc",
                "-e", "BTCPAY_BTCEXPLORERURL=http://archy-nbxplorer:32838",
                "-e", "BTCPAY_BTCRPCURL=http://host.containers.internal:8332",
                "-e", &format!("BTCPAY_BTCRPCUSER={}", rpc_user),
                "-e", &format!("BTCPAY_BTCRPCPASSWORD={}", rpc_pass),
                "-e", &format!(
                    "BTCPAY_POSTGRES=User ID=btcpay;Password={};Host=archy-btcpay-db;Port=5432;Database=btcpay;Include Error Detail=true",
                    db_pass
                ),
                "docker.io/btcpayserver/btcpayserver:2.4.3",
            ])
            .output()
            .await
            .context("Failed to start btcpay-server")?;

        if !run.status.success() {
            let stderr = String::from_utf8_lossy(&run.stderr);
            install_log(&format!("INSTALL FAIL: btcpay-server — {}", stderr)).await;
            return Err(anyhow::anyhow!("Failed to start BTCPay Server: {}", stderr));
        }

        self.set_install_phase("btcpay-server", InstallPhase::WaitingHealthy)
            .await;
        self.set_install_phase("btcpay-server", InstallPhase::PostInstall)
            .await;
        self.set_install_phase("btcpay-server", InstallPhase::Done)
            .await;
        self.clear_install_progress("btcpay-server").await;

        install_log("INSTALL OK: btcpay-server stack").await;
        info!("BTCPay stack installed and started");
        Ok(serde_json::json!({
            "success": true,
            "package_id": "btcpay-server",
            "message": "BTCPay stack installed and started",
            "container_id": String::from_utf8_lossy(&run.stdout).trim().to_string(),
        }))
    }

    /// Install Mempool stack (mariadb + mempool-api + mempool-web).
    pub(super) async fn install_mempool_stack(&self) -> Result<serde_json::Value> {
        super::dependencies::check_bitcoin_pruning_compatibility("mempool").await?;

        if let Some(adopted) = adopt_stack_if_exists(
            "mempool",
            "mempool",
            &[
                "archy-mempool-db",
                "mempool-api",
                "mempool",
                "archy-mempool-web",
                "archy-mempool-api",
            ],
        )
        .await?
        {
            return Ok(adopted);
        }

        if let Some(orchestrated) =
            install_stack_via_orchestrator(self, "mempool", mempool_stack_app_ids()).await?
        {
            return Ok(orchestrated);
        }

        // Dependency check: Bitcoin + ElectrumX must be running
        let deps = super::dependencies::detect_running_deps().await?;
        super::dependencies::check_install_deps("mempool", &deps)?;
        let (_, rpc_pass) = crate::bitcoin_rpc::bitcoin_rpc_credentials().await;
        // CORE_RPC_HOST must match the actual Bitcoin node container name —
        // bitcoin-knots OR bitcoin-core — else mempool-api can't reach RPC (B12).
        let bitcoin_rpc_host = super::dependencies::detect_bitcoin_rpc_host().await;

        install_log("INSTALL START: mempool (stack: mariadb + mempool-api + mempool-web)").await;

        let db_pass = super::config::read_or_generate_secret("mempool-db-password").await;
        let root_pass = super::config::read_or_generate_secret("mysql-root-db-password").await;

        let images = [
            &format!("{}/mariadb:11.4.10", REGISTRY),
            &format!("{}/mempool-backend:v3.0.0", REGISTRY),
            &format!("{}/mempool-frontend:v3.0.0", REGISTRY),
        ];
        self.set_install_phase("mempool", InstallPhase::PullingImage)
            .await;
        let n_images = images.len() as u64;
        for (i, img) in images.iter().enumerate() {
            self.set_install_progress("mempool", i as u64, n_images)
                .await;
            pull_image_with_retry(img).await?;
        }
        self.set_install_progress("mempool", n_images, n_images)
            .await;
        self.set_install_phase("mempool", InstallPhase::CreatingContainer)
            .await;

        // Create data dirs (chown to current user so rootless podman can write)
        let _ = tokio::process::Command::new("sudo")
            .args([
                "mkdir",
                "-p",
                "/var/lib/archipelago/mysql-mempool",
                "/var/lib/archipelago/mempool",
            ])
            .output()
            .await;
        let user = std::env::var("USER").unwrap_or_else(|_| "archipelago".to_string());
        for dir in &[
            "/var/lib/archipelago/mysql-mempool",
            "/var/lib/archipelago/mempool",
        ] {
            let _ = tokio::process::Command::new("sudo")
                .args(["chown", "-R", &format!("{}:{}", user, user), dir])
                .output()
                .await;
        }

        // Ensure archy-net exists
        let _ = podman_stack_output(
            &["network", "create", "archy-net"],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;

        // 1. MariaDB
        let _ = tokio::process::Command::new("podman")
            .args([
                "run",
                "-d",
                "--name",
                "archy-mempool-db",
                "--restart",
                "unless-stopped",
                "--network",
                "archy-net",
                "--network-alias",
                "archy-mempool-db",
                "--cap-drop=ALL",
                "--cap-add=CHOWN",
                "--cap-add=DAC_OVERRIDE",
                "--cap-add=FOWNER",
                "--cap-add=SETGID",
                "--cap-add=SETUID",
                "--security-opt=no-new-privileges:true",
                "--memory=512m",
                "--pids-limit=4096",
                "--health-cmd=mariadb-admin ping -u root --password=$MYSQL_ROOT_PASSWORD || exit 1",
                "--health-interval=30s",
                "--health-retries=3",
                "-v",
                "/var/lib/archipelago/mysql-mempool:/var/lib/mysql",
                "-e",
                "MYSQL_DATABASE=mempool",
                "-e",
                "MYSQL_USER=mempool",
                "-e",
                &format!("MYSQL_PASSWORD={}", db_pass),
                "-e",
                &format!("MYSQL_ROOT_PASSWORD={}", root_pass),
                &format!("{}/mariadb:11.4.10", REGISTRY),
            ])
            .output()
            .await;
        tokio::time::sleep(std::time::Duration::from_secs(10)).await;

        // 2. Mempool API backend
        let _ = tokio::process::Command::new("podman")
            .args([
                "run",
                "-d",
                "--name",
                "mempool-api",
                "--restart",
                "unless-stopped",
                "--network",
                "archy-net",
                "--network-alias",
                "mempool-api",
                "--cap-drop=ALL",
                "--security-opt=no-new-privileges:true",
                "--memory=512m",
                "--pids-limit=4096",
                "-p",
                "8999:8999",
                "-v",
                "/var/lib/archipelago/mempool:/data",
                "-e",
                "MEMPOOL_BACKEND=electrum",
                "-e",
                "ELECTRUM_HOST=electrumx",
                "-e",
                "ELECTRUM_PORT=50001",
                "-e",
                "ELECTRUM_TLS_ENABLED=false",
                "-e",
                &format!("CORE_RPC_HOST={}", bitcoin_rpc_host),
                "-e",
                "CORE_RPC_PORT=8332",
                "-e",
                "CORE_RPC_USERNAME=archipelago",
                "-e",
                &format!("CORE_RPC_PASSWORD={}", rpc_pass),
                "-e",
                "DATABASE_ENABLED=true",
                "-e",
                "DATABASE_HOST=archy-mempool-db",
                "-e",
                "DATABASE_DATABASE=mempool",
                "-e",
                "DATABASE_USERNAME=mempool",
                "-e",
                &format!("DATABASE_PASSWORD={}", db_pass),
                &format!("{}/mempool-backend:v3.0.0", REGISTRY),
            ])
            .output()
            .await;
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;

        // 3. Mempool frontend
        let run = tokio::process::Command::new("podman")
            .args([
                "run",
                "-d",
                "--name",
                "mempool",
                "--restart",
                "unless-stopped",
                "--network",
                "archy-net",
                "--network-alias",
                "mempool",
                "--cap-drop=ALL",
                "--security-opt=no-new-privileges:true",
                "--memory=256m",
                "--pids-limit=2048",
                "-p",
                "4080:8080",
                "-e",
                "FRONTEND_HTTP_PORT=8080",
                "-e",
                "BACKEND_MAINNET_HTTP_HOST=mempool-api",
                &format!("{}/mempool-frontend:v3.0.0", REGISTRY),
            ])
            .output()
            .await
            .context("Failed to start mempool frontend")?;

        if !run.status.success() {
            let stderr = String::from_utf8_lossy(&run.stderr);
            install_log(&format!("INSTALL FAIL: mempool — {}", stderr)).await;
            return Err(anyhow::anyhow!("Failed to start Mempool: {}", stderr));
        }

        self.set_install_phase("mempool", InstallPhase::WaitingHealthy)
            .await;
        self.set_install_phase("mempool", InstallPhase::PostInstall)
            .await;
        self.set_install_phase("mempool", InstallPhase::Done).await;
        self.clear_install_progress("mempool").await;

        install_log("INSTALL OK: mempool stack").await;
        info!("Mempool stack installed and started");
        Ok(serde_json::json!({
            "success": true,
            "package_id": "mempool",
            "message": "Mempool stack installed and started",
            "container_id": String::from_utf8_lossy(&run.stdout).trim().to_string(),
        }))
    }

    /// Install the IndeedHub multi-container stack.
    pub(super) async fn install_indeedhub_stack(&self) -> Result<serde_json::Value> {
        // Manifest-driven path (#20 phase 3): render the 7-member stack from
        // apps/indeedhub-*/manifest.yml via the orchestrator (dedicated
        // indeedhub-net + network_aliases, generated_secrets, the frontend's
        // post_install nginx hook, reboot-survivable). The manifests use the exact
        // live container names / named volumes, so on an existing node this ADOPTS
        // the running stack rather than recreating it (data preserved). Falls back
        // to the legacy installer below only when the orchestrator doesn't know
        // these app_ids (manifests not yet deployed). See PRODUCTION-MASTER-PLAN.md.
        if let Some(orchestrated) =
            install_stack_via_orchestrator(self, "indeedhub", indeedhub_stack_app_ids()).await?
        {
            return Ok(orchestrated);
        }

        let registry = crate::container::registry::load_registries(&self.config.data_dir)
            .await
            .unwrap_or_default()
            .registries
            .into_iter()
            .find(|r| r.enabled)
            .map(|r| r.url)
            .unwrap_or_else(|| "source.archipelago-foundation.org/lfg2025".to_string());

        let user_tmp = format!(
            "{}/.local/share/containers/tmp",
            std::env::var("HOME").unwrap_or_else(|_| "/home/archipelago".to_string())
        );
        let _ = std::fs::create_dir_all(&user_tmp);

        install_log("INSTALL START: indeedhub stack").await;
        info!("Installing IndeedHub stack from {}", registry);

        // Pull all images
        let images = [
            format!("{}/postgres:16.13-alpine", registry),
            format!("{}/redis:7.4.8-alpine", registry),
            format!("{}/minio:RELEASE.2024-11-07T00-52-20Z", registry),
            format!("{}/nostr-rs-relay:0.9.0", registry),
            format!("{}/indeedhub-api:1.0.0", registry),
            format!("{}/indeedhub-ffmpeg:1.0.0", registry),
            format!("{}/indeedhub:1.0.0", registry),
        ];

        // Pull all images with retry; fail the install if any image can't be pulled.
        // Previously this just logged a warning and continued, leaving the stack
        // broken and the user seeing "failed" with no recovery path.
        self.set_install_phase("indeedhub", InstallPhase::PullingImage)
            .await;
        let n_images = images.len() as u64;
        for (i, img) in images.iter().enumerate() {
            // set_install_progress fills the byte-counter fallback the UI uses
            // when it can't read podman's pull output — gives the bar a clear
            // X-of-N step as each image lands.
            self.set_install_progress("indeedhub", i as u64, n_images)
                .await;
            info!("Pulling {}", img);
            pull_image_with_retry(img)
                .await
                .with_context(|| format!("Failed to pull IndeedHub image: {}", img))?;
        }
        self.set_install_progress("indeedhub", n_images, n_images)
            .await;

        // The retired installer injected one fleet-wide AES root directly in
        // the API/worker environment. Detect those consumers before removing
        // anything, then persist the legacy value exactly once so an upgrade
        // cannot orphan encrypted data. A genuinely fresh fallback install
        // receives a random per-node root instead.
        let mut had_existing_crypto_consumer = false;
        for name in [
            "indeedhub-api",
            "indeedhub-ffmpeg",
            "indeedhub-build_api_1",
            "indeedhub-build_ffmpeg-worker_1",
        ] {
            let status =
                podman_stack_status(&["container", "exists", name], PODMAN_STACK_PROBE_TIMEOUT)
                    .await?;
            had_existing_crypto_consumer |= status.success();
        }
        let secrets_dir = self.config.data_dir.join("secrets");
        crate::container::secrets::ensure_indeedhub_aes_master_secret(
            &secrets_dir,
            had_existing_crypto_consumer,
        )
        .context("preparing IndeedHub encryption root")?;
        let aes_master = crate::container::secrets::indeedhub_aes_master_secret(&secrets_dir)?;

        // Remove any leftover containers from a previous partial install (or
        // from the first-boot frontend stub that used to race the installer).
        // Without this, `podman run --name indeedhub` fails on name conflict
        // and the whole stack install errors out — leaving a half-broken node.
        for name in [
            "indeedhub",
            "indeedhub-postgres",
            "indeedhub-redis",
            "indeedhub-minio",
            "indeedhub-relay",
            "indeedhub-api",
            "indeedhub-ffmpeg",
            "indeedhub-build_api_1",
            "indeedhub-build_ffmpeg-worker_1",
        ] {
            force_remove_stack_container(name)
                .await
                .with_context(|| format!("Failed to clear stale IndeedHub container {}", name))?;
        }
        let _ = podman_stack_status(
            &["network", "rm", "-f", "indeedhub-net"],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;

        // Phase: CreatingContainer — pulls done, network rebuilt, now spinning
        // up the 7 stack containers. Bar advances from PullingImage band into
        // CreatingContainer band so the user sees movement.
        self.set_install_phase("indeedhub", InstallPhase::CreatingContainer)
            .await;

        // Create indeedhub-net
        let _ = podman_stack_status(
            &["network", "create", "indeedhub-net"],
            PODMAN_STACK_PROBE_TIMEOUT,
        )
        .await;

        // Generate secrets
        let db_pass = super::config::read_or_generate_secret("indeedhub-db-password").await;
        let jwt_secret = super::config::read_or_generate_secret("indeedhub-jwt").await;
        let minio_user = "indeeadmin";
        let minio_pass = super::config::read_or_generate_secret("indeedhub-minio-password").await;

        let tmp_env = [format!("TMPDIR={user_tmp}")];

        // 1. Postgres
        run_required_scoped_podman_stack_command_with_env(
            "indeedhub",
            "create postgres",
            vec![
                "run".to_string(),
                "-d".to_string(),
                "--name".to_string(),
                "indeedhub-postgres".to_string(),
                "--network".to_string(),
                "indeedhub-net".to_string(),
                "--network-alias".to_string(),
                "postgres".to_string(),
                "--restart".to_string(),
                "unless-stopped".to_string(),
                "-e".to_string(),
                "POSTGRES_DB=indeedhub".to_string(),
                "-e".to_string(),
                "POSTGRES_USER=indeedhub".to_string(),
                "-e".to_string(),
                format!("POSTGRES_PASSWORD={db_pass}"),
                "-v".to_string(),
                "indeedhub-postgres-data:/var/lib/postgresql/data".to_string(),
                format!("{registry}/postgres:16.13-alpine"),
            ],
            &tmp_env,
        )
        .await?;

        // 2. Redis
        run_required_scoped_podman_stack_command_with_env(
            "indeedhub",
            "create redis",
            vec![
                "run".to_string(),
                "-d".to_string(),
                "--name".to_string(),
                "indeedhub-redis".to_string(),
                "--network".to_string(),
                "indeedhub-net".to_string(),
                "--network-alias".to_string(),
                "redis".to_string(),
                "--restart".to_string(),
                "unless-stopped".to_string(),
                "-v".to_string(),
                "indeedhub-redis-data:/data".to_string(),
                format!("{registry}/redis:7.4.8-alpine"),
            ],
            &tmp_env,
        )
        .await?;

        // 3. MinIO
        run_required_scoped_podman_stack_command_with_env(
            "indeedhub",
            "create minio",
            vec![
                "run".to_string(),
                "-d".to_string(),
                "--name".to_string(),
                "indeedhub-minio".to_string(),
                "--network".to_string(),
                "indeedhub-net".to_string(),
                "--network-alias".to_string(),
                "minio".to_string(),
                "--restart".to_string(),
                "unless-stopped".to_string(),
                "-e".to_string(),
                format!("MINIO_ROOT_USER={minio_user}"),
                "-e".to_string(),
                format!("MINIO_ROOT_PASSWORD={minio_pass}"),
                "-v".to_string(),
                "indeedhub-minio-data:/data".to_string(),
                format!("{registry}/minio:RELEASE.2024-11-07T00-52-20Z"),
                "server".to_string(),
                "/data".to_string(),
            ],
            &tmp_env,
        )
        .await?;

        // 4. Nostr relay
        run_required_scoped_podman_stack_command_with_env(
            "indeedhub",
            "create relay",
            vec![
                "run".to_string(),
                "-d".to_string(),
                "--name".to_string(),
                "indeedhub-relay".to_string(),
                "--network".to_string(),
                "indeedhub-net".to_string(),
                "--network-alias".to_string(),
                "relay".to_string(),
                "--restart".to_string(),
                "unless-stopped".to_string(),
                "-v".to_string(),
                "indeedhub-relay-data:/usr/src/app/db".to_string(),
                format!("{registry}/nostr-rs-relay:0.9.0"),
            ],
            &tmp_env,
        )
        .await?;

        // 5. API
        run_required_scoped_podman_stack_command_with_env(
            "indeedhub",
            "create api",
            vec![
                "run".to_string(),
                "-d".to_string(),
                "--name".to_string(),
                "indeedhub-api".to_string(),
                "--network".to_string(),
                "indeedhub-net".to_string(),
                "--network-alias".to_string(),
                "api".to_string(),
                "--restart".to_string(),
                "unless-stopped".to_string(),
                "-e".to_string(),
                "PORT=4000".to_string(),
                "-e".to_string(),
                "DATABASE_HOST=postgres".to_string(),
                "-e".to_string(),
                "DATABASE_PORT=5432".to_string(),
                "-e".to_string(),
                "DATABASE_USER=indeedhub".to_string(),
                "-e".to_string(),
                format!("DATABASE_PASSWORD={db_pass}"),
                "-e".to_string(),
                "DATABASE_NAME=indeedhub".to_string(),
                "-e".to_string(),
                "QUEUE_HOST=redis".to_string(),
                "-e".to_string(),
                "QUEUE_PORT=6379".to_string(),
                "-e".to_string(),
                "S3_ENDPOINT=http://minio:9000".to_string(),
                "-e".to_string(),
                "AWS_REGION=us-east-1".to_string(),
                "-e".to_string(),
                format!("AWS_ACCESS_KEY={minio_user}"),
                "-e".to_string(),
                format!("AWS_SECRET_KEY={minio_pass}"),
                "-e".to_string(),
                "S3_PUBLIC_BUCKET_NAME=indeedhub-public".to_string(),
                "-e".to_string(),
                "S3_PRIVATE_BUCKET_NAME=indeedhub-private".to_string(),
                "-e".to_string(),
                "S3_PUBLIC_BUCKET_URL=/storage".to_string(),
                "-e".to_string(),
                format!("NOSTR_JWT_SECRET={jwt_secret}"),
                "-e".to_string(),
                "NOSTR_JWT_EXPIRES_IN=7d".to_string(),
                "-e".to_string(),
                format!("AES_MASTER_SECRET={aes_master}"),
                "-e".to_string(),
                "ENVIRONMENT=production".to_string(),
                format!("{registry}/indeedhub-api:1.0.0"),
            ],
            &tmp_env,
        )
        .await?;

        // 6. FFmpeg worker
        run_required_scoped_podman_stack_command_with_env(
            "indeedhub",
            "create ffmpeg worker",
            vec![
                "run".to_string(),
                "-d".to_string(),
                "--name".to_string(),
                "indeedhub-ffmpeg".to_string(),
                "--network".to_string(),
                "indeedhub-net".to_string(),
                "--restart".to_string(),
                "unless-stopped".to_string(),
                "-e".to_string(),
                "DATABASE_HOST=postgres".to_string(),
                "-e".to_string(),
                "DATABASE_PORT=5432".to_string(),
                "-e".to_string(),
                "DATABASE_USER=indeedhub".to_string(),
                "-e".to_string(),
                format!("DATABASE_PASSWORD={db_pass}"),
                "-e".to_string(),
                "DATABASE_NAME=indeedhub".to_string(),
                "-e".to_string(),
                "QUEUE_HOST=redis".to_string(),
                "-e".to_string(),
                "QUEUE_PORT=6379".to_string(),
                "-e".to_string(),
                "S3_ENDPOINT=http://minio:9000".to_string(),
                "-e".to_string(),
                format!("AWS_ACCESS_KEY={minio_user}"),
                "-e".to_string(),
                format!("AWS_SECRET_KEY={minio_pass}"),
                "-e".to_string(),
                "AWS_REGION=us-east-1".to_string(),
                "-e".to_string(),
                "S3_PUBLIC_BUCKET_NAME=indeedhub-public".to_string(),
                "-e".to_string(),
                "S3_PRIVATE_BUCKET_NAME=indeedhub-private".to_string(),
                "-e".to_string(),
                "ENVIRONMENT=production".to_string(),
                "-e".to_string(),
                format!("AES_MASTER_SECRET={aes_master}"),
                format!("{registry}/indeedhub-ffmpeg:1.0.0"),
            ],
            &tmp_env,
        )
        .await?;

        // Wait for backend services to start
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;

        // 7. Frontend (nginx)
        run_required_scoped_podman_stack_command_with_env(
            "indeedhub",
            "create frontend",
            vec![
                "run".to_string(),
                "-d".to_string(),
                "--name".to_string(),
                "indeedhub".to_string(),
                "--network".to_string(),
                "indeedhub-net".to_string(),
                "--restart".to_string(),
                "unless-stopped".to_string(),
                "--tmpfs".to_string(),
                "/run:rw,nosuid,nodev,size=16m".to_string(),
                "--tmpfs".to_string(),
                "/var/cache/nginx:rw,nosuid,nodev,size=32m".to_string(),
                "-p".to_string(),
                "7778:7777".to_string(),
                format!("{}/indeedhub:1.0.0", registry),
            ],
            &tmp_env,
        )
        .await?;

        wait_for_stack_containers(
            "indeedhub",
            &[
                "indeedhub-postgres",
                "indeedhub-redis",
                "indeedhub-minio",
                "indeedhub-relay",
                "indeedhub-api",
                "indeedhub-ffmpeg",
                "indeedhub",
            ],
            60,
        )
        .await?;

        // Phase: WaitingHealthy → PostInstall → clear. The actual readiness
        // gate is the package scanner's next sweep; this just gives the UI a
        // truthful end-of-install signal so the bar settles at 95→100→done
        // instead of sitting at "Queued… 2%" forever.
        self.set_install_phase("indeedhub", InstallPhase::WaitingHealthy)
            .await;
        self.set_install_phase("indeedhub", InstallPhase::PostInstall)
            .await;
        self.set_install_phase("indeedhub", InstallPhase::Done)
            .await;
        self.clear_install_progress("indeedhub").await;

        patch_indeedhub_nostr_provider().await;

        install_log("INSTALL OK: indeedhub stack").await;
        info!("IndeedHub stack installed");
        Ok(serde_json::json!({
            "success": true,
            "package_id": "indeedhub",
            "message": "IndeedHub stack installed (7 containers)",
        }))
    }

    /// Install self-hosted NetBird (dashboard + combined management/signal/relay server).
    pub(super) async fn install_netbird_stack(&self) -> Result<serde_json::Value> {
        // Manifest-driven path (#20 phase 4): render the 3-member stack from
        // apps/netbird-*/manifest.yml via the orchestrator — dedicated
        // netbird-net + network_aliases, base64 generated_secrets, a self-signed
        // TLS cert (generated_certs) so the dashboard gets a secure context for
        // OIDC PKCE (#15), and templated config.yaml/nginx.conf rendered from
        // host facts + the netbird-net gateway. The manifests use the exact live
        // container names, so on an existing node this ADOPTS the running stack
        // rather than recreating it (the sqlite store + base64 keys are
        // preserved — ensure_generated_secrets no-ops on existing files).
        //
        // #20 ph4: the legacy hardcoded `podman run` installer was DELETED — the
        // signed catalog always ships apps/netbird-*/manifest.yml, so there is no
        // in-Rust fallback. If the orchestrator doesn't know these app_ids and no
        // running stack exists to adopt, install errors rather than silently
        // diverging from the manifest contract.
        if let Some(orchestrated) =
            install_stack_via_orchestrator(self, "netbird", netbird_stack_app_ids()).await?
        {
            return Ok(orchestrated);
        }

        if let Some(adopted) = adopt_stack_if_exists(
            "netbird",
            "netbird",
            &["netbird-server", "netbird-dashboard", "netbird"],
        )
        .await?
        {
            return Ok(adopted);
        }

        anyhow::bail!(
            "netbird manifests not available on this node — the signed catalog must provide apps/netbird-*/manifest.yml (legacy hardcoded installer removed in #20 ph4)"
        )
    }

    /// Install the Pine voice-assistant stack (Whisper STT + Piper TTS + the
    /// setup/status launcher). Manifest-driven only, like netbird: render the
    /// 3-member stack from apps/pine-*/manifest.yml via the orchestrator
    /// (archy-net + network_aliases, published Wyoming ports 10300/10200 so
    /// Home Assistant reaches the engines via host.containers.internal, the
    /// launcher's setup page written via `files:`). The manifests use the exact
    /// live container names, so on an existing node this ADOPTS the running
    /// stack rather than recreating it (downloaded models/voices preserved).
    ///
    /// There is no in-Rust hardcoded fallback: the signed catalog always ships
    /// apps/pine-*/manifest.yml. If the orchestrator doesn't know these app_ids
    /// and no running stack exists to adopt, install errors rather than
    /// silently diverging from the manifest contract.
    pub(super) async fn install_pine_stack(&self) -> Result<serde_json::Value> {
        if let Some(orchestrated) =
            install_stack_via_orchestrator(self, "pine", pine_stack_app_ids()).await?
        {
            Self::seed_pine_ha_defaults().await;
            return Ok(orchestrated);
        }

        if let Some(adopted) = adopt_stack_if_exists(
            "pine",
            "pine",
            &["pine-whisper", "pine-piper", "pine-openwakeword", "pine"],
        )
        .await?
        {
            Self::seed_pine_ha_defaults().await;
            return Ok(adopted);
        }

        anyhow::bail!(
            "pine manifests not available on this node — the signed catalog must provide apps/pine-*/manifest.yml"
        )
    }

    /// After a Pine install, wire Home Assistant to the new engines when HA is
    /// on this node (the HA post-install hook covers the reverse order).
    async fn seed_pine_ha_defaults() {
        if !super::pine_ha::home_assistant_installed().await {
            return;
        }
        if super::pine_ha::seed_home_assistant_pine_defaults().await {
            super::pine_ha::restart_home_assistant_if_running().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{btcpay_stack_app_ids, mempool_stack_app_ids};

    #[test]
    fn stack_app_id_sets_match_migration_manifests() {
        assert_eq!(
            btcpay_stack_app_ids(),
            ["archy-btcpay-db", "archy-nbxplorer", "btcpay-server"]
        );
        assert_eq!(
            mempool_stack_app_ids(),
            ["archy-mempool-db", "mempool-api", "archy-mempool-web"]
        );
    }
}
