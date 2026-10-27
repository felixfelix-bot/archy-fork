use anyhow::{Context, Result};
use ssh2::Session;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::Path;
use tracing::debug;

/// An active SSH connection to an OpenWrt router.
pub struct Router {
    pub host: String,
    pub port: u16,
    session: Session,
    #[cfg(test)]
    command: Option<Box<TestCommand>>,
}

#[cfg(test)]
type TestCommand = dyn Fn(&str) -> Result<(String, i32)> + Send + Sync;

impl Router {
    #[cfg(test)]
    pub(crate) fn scripted(
        command: impl Fn(&str) -> Result<(String, i32)> + Send + Sync + 'static,
    ) -> Self {
        Self {
            host: "scripted".into(),
            port: 0,
            session: Session::new().unwrap(),
            command: Some(Box::new(command)),
        }
    }
    /// Bounded TCP connect. The OS default connect timeout against an
    /// unreachable RFC1918 address is ~2 minutes; a router that stayed
    /// behind when its node moved networks turned every status poll into a
    /// worker-thread hostage for that long, stalling unrelated RPCs
    /// (framework-pt, 2026-08-15 — even TOTP codes expired in flight).
    /// Read/write timeouts bound the session the same way once connected.
    fn bounded_tcp(host: &str, port: u16) -> Result<TcpStream> {
        use std::net::ToSocketAddrs;
        let addr = format!("{}:{}", host, port);
        let resolved = addr
            .to_socket_addrs()
            .with_context(|| format!("resolve {}", addr))?
            .next()
            .with_context(|| format!("no address for {}", addr))?;
        let tcp = TcpStream::connect_timeout(&resolved, std::time::Duration::from_secs(5))
            .with_context(|| format!("TCP connect to {}", addr))?;
        tcp.set_read_timeout(Some(std::time::Duration::from_secs(30)))
            .ok();
        tcp.set_write_timeout(Some(std::time::Duration::from_secs(30)))
            .ok();
        Ok(tcp)
    }

    /// Connect to an OpenWrt router via SSH using a private key.
    pub fn connect(host: &str, port: u16, user: &str, key_path: &Path) -> Result<Self> {
        let tcp = Self::bounded_tcp(host, port)?;

        let mut session = Session::new().context("create SSH session")?;
        session.set_tcp_stream(tcp);
        session.handshake().context("SSH handshake")?;
        session
            .userauth_pubkey_file(user, None, key_path, None)
            .with_context(|| format!("SSH auth as {} with key {:?}", user, key_path))?;

        Ok(Self {
            host: host.to_string(),
            port,
            session,
            #[cfg(test)]
            command: None,
        })
    }

    /// Connect using a password (fallback for routers not yet provisioned with a key).
    pub fn connect_password(host: &str, port: u16, user: &str, password: &str) -> Result<Self> {
        let tcp = Self::bounded_tcp(host, port)?;

        let mut session = Session::new().context("create SSH session")?;
        session.set_tcp_stream(tcp);
        session.handshake().context("SSH handshake")?;
        session
            .userauth_password(user, password)
            .with_context(|| format!("SSH password auth as {}", user))?;

        Ok(Self {
            host: host.to_string(),
            port,
            session,
            #[cfg(test)]
            command: None,
        })
    }

    /// Run a command and return (stdout, exit_code).
    pub fn run(&self, cmd: &str) -> Result<(String, i32)> {
        #[cfg(test)]
        if let Some(command) = &self.command {
            return command(cmd);
        }
        debug!("ssh [{}] $ {}", self.host, cmd);

        let mut channel = self.session.channel_session().context("open channel")?;
        channel
            .exec(cmd)
            .with_context(|| format!("exec: {}", cmd))?;

        let mut stdout = String::new();
        channel.read_to_string(&mut stdout).context("read stdout")?;
        channel.wait_close().context("wait close")?;
        let exit = channel.exit_status().context("exit status")?;

        Ok((stdout, exit))
    }

    /// Run a command, fail if exit code is non-zero.
    pub fn run_ok(&self, cmd: &str) -> Result<String> {
        let (out, code) = self.run(cmd)?;
        if code != 0 {
            anyhow::bail!(
                "command `{}` exited with code {}: {}",
                cmd,
                code,
                out.trim()
            );
        }
        Ok(out)
    }

    /// Verify the remote device is actually running OpenWrt.
    pub fn verify_openwrt(&self) -> Result<String> {
        let release = self
            .run_ok("cat /etc/openwrt_release")
            .context("read /etc/openwrt_release — is this an OpenWrt device?")?;
        Ok(release)
    }

    /// Upload file contents to the router over SCP, overwriting any existing
    /// file at `remote_path`. Used for config files that aren't UCI-backed
    /// (e.g. `/etc/tollgate/config.json`), where `uci_*` helpers don't apply.
    pub fn upload_file(&self, remote_path: &str, contents: &[u8]) -> Result<()> {
        let mut channel = self
            .session
            .scp_send(Path::new(remote_path), 0o644, contents.len() as u64, None)
            .with_context(|| format!("scp_send to {}", remote_path))?;
        channel
            .write_all(contents)
            .with_context(|| format!("write contents to {}", remote_path))?;
        channel.send_eof().context("scp send_eof")?;
        channel.wait_eof().context("scp wait_eof")?;
        channel.close().context("scp close")?;
        channel.wait_close().context("scp wait_close")?;
        Ok(())
    }
}
