mod discovery_guard;
mod tools;

use clap::{Parser, Subcommand};
use rmcp::service::RoleServer;
use rmcp::transport::{stdio, IntoTransport};
use rmcp::ServiceExt;

use discovery_guard::DiscoveryGuard;

#[derive(Parser)]
#[command(name = "devcontainer-mcp")]
#[command(about = "MCP server and CLI for managing DevContainers")]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the MCP server over stdio
    Serve,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();

    let cli = Cli::parse();

    match cli.command {
        Commands::Serve => {
            tracing::info!("Starting devcontainer-mcp MCP server over stdio");
            let service = tools::DevContainerMcp::new();
            // Wrap stdio so an optimistic pre-initialize `server/discover` probe
            // (sent by some hosts, e.g. the GitHub Copilot CLI) is answered with
            // `Method not found` instead of aborting the handshake.
            let transport =
                DiscoveryGuard::new(IntoTransport::<RoleServer, _, _>::into_transport(stdio()));
            let server = service.serve(transport).await?;
            server.waiting().await?;
        }
    }

    Ok(())
}
