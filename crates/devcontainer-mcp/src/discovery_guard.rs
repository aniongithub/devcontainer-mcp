//! Transport wrapper that keeps the server alive through pre-initialize probes.
//!
//! Some MCP hosts (notably the GitHub Copilot CLI) send an optimistic
//! `server/discover` request *before* the standard `initialize` handshake. A
//! spec-compliant server is expected to answer an unknown method with a
//! JSON-RPC `-32601 Method not found` error and stay running, at which point
//! the host falls back to the normal `initialize` flow.
//!
//! rmcp's server handshake instead treats the first non-`ping` request as the
//! `initialize` request; when it isn't, `serve()` returns an error, `main`
//! exits, and stdin is closed before the host's fallback `initialize` arrives
//! ("broken pipe"). This wrapper intercepts any request received before
//! `initialize`, replies with `Method not found`, and keeps waiting so the
//! real handshake can proceed.

use rmcp::model::{
    ClientJsonRpcMessage, ClientRequest, ErrorCode, ErrorData, RequestId, ServerJsonRpcMessage,
};
use rmcp::service::RoleServer;
use rmcp::transport::Transport;

pub struct DiscoveryGuard<T> {
    inner: T,
    initialized: bool,
}

impl<T> DiscoveryGuard<T> {
    pub fn new(inner: T) -> Self {
        Self {
            inner,
            initialized: false,
        }
    }
}

enum PreInit {
    Forward,
    Reply(RequestId, String),
}

impl<T> Transport<RoleServer> for DiscoveryGuard<T>
where
    T: Transport<RoleServer> + Send,
{
    type Error = T::Error;

    fn send(
        &mut self,
        item: ServerJsonRpcMessage,
    ) -> impl std::future::Future<Output = Result<(), Self::Error>> + Send + 'static {
        self.inner.send(item)
    }

    async fn receive(&mut self) -> Option<ClientJsonRpcMessage> {
        loop {
            let msg = self.inner.receive().await?;
            if self.initialized {
                return Some(msg);
            }

            let action = match &msg {
                ClientJsonRpcMessage::Request(req) => match &req.request {
                    ClientRequest::InitializeRequest(_) => {
                        self.initialized = true;
                        PreInit::Forward
                    }
                    // Let rmcp answer pre-init pings itself (allowed by the spec).
                    ClientRequest::PingRequest(_) => PreInit::Forward,
                    other => PreInit::Reply(req.id.clone(), other.method().to_string()),
                },
                _ => PreInit::Forward,
            };

            match action {
                PreInit::Forward => return Some(msg),
                PreInit::Reply(id, method) => {
                    let response = ServerJsonRpcMessage::error(
                        ErrorData::new(
                            ErrorCode::METHOD_NOT_FOUND,
                            format!("method not available before initialization: {method}"),
                            None,
                        ),
                        id,
                    );
                    // Best-effort: if the client hung up, the next receive() ends the loop.
                    let _ = self.inner.send(response).await;
                    continue;
                }
            }
        }
    }

    fn close(&mut self) -> impl std::future::Future<Output = Result<(), Self::Error>> + Send {
        self.inner.close()
    }
}

#[cfg(test)]
mod tests {
    use super::DiscoveryGuard;
    use crate::tools::DevContainerMcp;
    use rmcp::service::RoleServer;
    use rmcp::transport::IntoTransport;
    use rmcp::ServiceExt;
    use serde_json::{json, Value};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, ReadHalf, WriteHalf};

    /// A minimal raw MCP client speaking newline-delimited JSON-RPC over an
    /// in-memory pipe — enough to replay a host handshake byte-for-byte,
    /// including the non-standard `server/discover` probe that rmcp's own
    /// client would never send.
    struct RawClient {
        writer: WriteHalf<DuplexStream>,
        reader: tokio::io::Lines<BufReader<ReadHalf<DuplexStream>>>,
    }

    impl RawClient {
        async fn send(&mut self, msg: Value) {
            let mut line = msg.to_string();
            line.push('\n');
            self.writer.write_all(line.as_bytes()).await.unwrap();
            self.writer.flush().await.unwrap();
        }

        async fn recv(&mut self) -> Value {
            let line = self
                .reader
                .next_line()
                .await
                .expect("read line")
                .expect("server closed stream unexpectedly");
            serde_json::from_str(&line).expect("valid JSON-RPC line")
        }
    }

    /// Spawn the real `DevContainerMcp` server behind `DiscoveryGuard` over an
    /// in-memory duplex and return a raw client wired to the other end.
    fn spawn_server() -> (RawClient, tokio::task::JoinHandle<()>) {
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);

        let handle = tokio::spawn(async move {
            let service = DevContainerMcp::new();
            let transport =
                DiscoveryGuard::new(IntoTransport::<RoleServer, _, _>::into_transport(server_io));
            let running = service.serve(transport).await.expect("server handshake");
            let _ = running.waiting().await;
        });

        let (read, write) = tokio::io::split(client_io);
        let client = RawClient {
            writer: write,
            reader: BufReader::new(read).lines(),
        };
        (client, handle)
    }

    fn initialize_msg(id: i64) -> Value {
        json!({
            "jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": { "name": "test-client", "version": "0.0.0" }
            }
        })
    }

    /// Regression test for the reported bug: the GitHub Copilot CLI sends an
    /// optimistic `server/discover` request before `initialize`. The server must
    /// answer it with `-32601 Method not found`, stay alive, and then complete a
    /// normal handshake so tools can be listed.
    #[tokio::test]
    async fn survives_pre_initialize_discover_probe() {
        let (mut client, handle) = spawn_server();

        // 1. Optimistic probe before initialize — must NOT crash the server.
        client
            .send(json!({"jsonrpc": "2.0", "id": 0, "method": "server/discover", "params": {}}))
            .await;
        let discover_reply = client.recv().await;
        assert_eq!(discover_reply["id"], 0);
        assert_eq!(discover_reply["error"]["code"], -32601);

        // 2. Fallback initialize — the server is still running and handshakes.
        client.send(initialize_msg(1)).await;
        let init_reply = client.recv().await;
        assert_eq!(init_reply["id"], 1);
        assert_eq!(init_reply["result"]["serverInfo"]["name"], "devcontainer-mcp");

        // 3. Complete the lifecycle and confirm tools are usable.
        client
            .send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
            .await;
        client
            .send(json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}))
            .await;
        let tools_reply = client.recv().await;
        assert_eq!(tools_reply["id"], 2);
        assert!(
            !tools_reply["result"]["tools"].as_array().unwrap().is_empty(),
            "expected a non-empty tool list"
        );

        handle.abort();
    }

    /// A normal handshake (no probe) must be unaffected by the wrapper.
    #[tokio::test]
    async fn normal_handshake_still_works() {
        let (mut client, handle) = spawn_server();

        client.send(initialize_msg(1)).await;
        let init_reply = client.recv().await;
        assert_eq!(init_reply["id"], 1);
        assert_eq!(init_reply["result"]["serverInfo"]["name"], "devcontainer-mcp");

        handle.abort();
    }
}
