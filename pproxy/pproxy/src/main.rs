/// Examples:
/// 1. https://github.com/randommm/pingora-reverse-proxy/blob/master/src/main.rs
/// 2. https://github.com/cloudflare/pingora/blob/main/pingora-proxy/examples/load_balancer.rs
use clap::Parser;
use std::net::ToSocketAddrs;


pub fn resolve_home(path: &std::path::Path) -> std::path::PathBuf {
   let path_str = path.to_string_lossy();
   if path.starts_with("~") {
      let home = std::env::var("HOME").expect("HOME environment variable not set");
      return Into::into(path_str.replacen('~', &home, 1));
   }
   Into::into(path)
}



#[derive(clap::Parser, Debug)]
#[command(version, about, long_about = None)]
struct Cli {
   /// Log-level. We are using env_logger, so everything can be configured with env-vars, but we also
   /// provide an option to configure it with a command-line arguments.
   /// See more info at https://docs.rs/env_logger/0.10.0/env_logger/
   #[arg(long)]
   #[arg(value_parser = clap::builder::PossibleValuesParser::new(["error", "warn", "info", "debug", "trace"]))]
   #[arg(default_value_t = String::from("info"))]
   log_level: String,

   /// Where to listen, for example: 0.0.0.0:6189
   #[arg(long)]
   listen_ip_port: String,

   /// Where to proxy/forward requests to, for example: 127.0.0.1:8888
   #[arg(long)]
   dest_ip_port: String,

   /// Path to private key
   #[arg(long)]
   priv_key: std::path::PathBuf,

   /// Path to certificate
   #[arg(long)]
   cert: std::path::PathBuf,

   #[arg(long)]
   ca: std::path::PathBuf,

   /// Externally visible domain name. Needed to create redirects
   #[arg(long)]
   redir_domain: String,
}
pub fn init_logger(log_level: &str) {
   let mut builder = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or(log_level));
   builder.format_timestamp_micros();
   builder.init();
}



// -----------------------------------------------------------------------------------------------------------
// main

fn redirect(domain: &str, path: &str) -> pingora_http::ResponseHeader {
   let mut res =
      pingora_http::ResponseHeader::build(http::status::StatusCode::MOVED_PERMANENTLY, Some(0)).unwrap();
   let loc = format!("https://{domain}/{path}");
   res.insert_header(http::header::LOCATION, loc).unwrap();
   res.insert_header(http::header::SERVER, domain).unwrap();
   res.insert_header(http::header::CONTENT_LENGTH, "0").unwrap();
   // resp.insert_header(http::header::DATE, "Sun, 06 Nov 1994 08:49:37 GMT").unwrap(); // placeholder
   // resp.insert_header(http::header::CACHE_CONTROL, "private, no-store").unwrap();
   res
}

/// Defines "upstream" (where we proxy TO) server
#[derive(Clone)]
pub struct Upstream {
   pub dest_addr: std::net::SocketAddr,
}


struct Proxy {
   upstream:    Upstream,
   listen_port: String,
   domain:      String,
}
#[async_trait::async_trait]
impl pingora_proxy::ProxyHttp for Proxy {
   type CTX = ();
   fn new_ctx(&self) -> Self::CTX {}

   async fn upstream_peer(&self,
                          _session: &mut pingora_proxy::Session,
                          _ctx: &mut ())
                          -> pingora_core::Result<Box<pingora_core::upstreams::peer::HttpPeer>> {
      let proxy_addr = pingora_core::protocols::l4::socket::SocketAddr::Inet(self.upstream.dest_addr);
      let dest = pingora_core::upstreams::peer::HttpPeer::new(proxy_addr, false, String::new());
      Ok(Box::new(dest))
   }

   async fn request_filter(&self,
                           session: &mut pingora_proxy::Session,
                           _ctx: &mut Self::CTX)
                           -> pingora_core::Result<bool> {
      log::info!("Got request: path: {}", session.req_header().uri.path());
      if session.req_header().uri.path() == "/.well-known/carddav"
         || session.req_header().uri.path() == "/.well-known/caldav"
      {
         // session.set_keepalive(None);
         let _ = session.write_response_header(Box::new(redirect(&self.domain, "remote.php/dav/"))).await;
         // true: tell the proxy that the response is already written
         return Ok(true);
      }
      Ok(false)
   }


   async fn upstream_request_filter(&self,
                                    _session: &mut pingora_proxy::Session,
                                    upstream_request: &mut pingora::http::RequestHeader,
                                    _ctx: &mut Self::CTX)
                                    -> pingora_core::Result<()> {
      let parts = upstream_request.as_ref();
      let combined: Vec<&str> =
         parts.headers.get_all(http::header::COOKIE).iter().map(|h| h.to_str().unwrap()).collect();
      let combined = combined.join("; ");
      // log::debug!("PCookies: combined: {combined:?}");
      upstream_request.insert_header(http::header::COOKIE, combined).unwrap();
      upstream_request.append_header("X-Forwarded-Proto", "https").unwrap();
      upstream_request.append_header("X-Forwarded-Scheme", "https").unwrap();
      upstream_request.append_header("X-Forwarded-Port", &self.listen_port).unwrap();
      Ok(())
   }

   async fn logging(&self,
                    session: &mut pingora_proxy::Session,
                    _e: Option<&pingora::Error>,
                    ctx: &mut Self::CTX) {
      let response_code = session.response_written().map_or(0, |resp| resp.status.as_u16());
      // access log
      log::info!("{} response code: {response_code}", self.request_summary(session, ctx));
   }
}




fn main() {
   let cli = Cli::parse();
   init_logger(&cli.log_level);

   let opt = pingora_core::server::configuration::Opt { upgrade:   false,
                                                        daemon:    false,
                                                        nocapture: false,
                                                        test:      false,
                                                        conf:      None, };
   let mut server = pingora_core::server::Server::new(Some(opt)).unwrap();
   server.bootstrap();

   let dest_addr = cli.dest_ip_port.to_socket_addrs().unwrap().next().unwrap();
   log::info!("Resolved {} into: {:?}", cli.dest_ip_port, dest_addr);
   let listen_port = cli.listen_ip_port.split(':').last().unwrap().parse().unwrap();
   let proxy = Proxy { upstream: Upstream { dest_addr },
                       listen_port,
                       domain: cli.redir_domain.clone() };
   let mut proxy = pingora_proxy::http_proxy_service(&server.configuration, proxy);

   let priv_key_path = resolve_home(&cli.priv_key).to_string_lossy().into_owned();
   let cert_path = resolve_home(&cli.cert).to_string_lossy().into_owned();
   let ca_path = resolve_home(&cli.ca);

   let mut tls = pingora_core::listeners::TlsSettings::intermediate(&cert_path, &priv_key_path).unwrap();
   tls.set_ca_file(ca_path).unwrap();

   tls.set_alpn(pingora_core::protocols::ssl::ALPN::H2H1);
   tls.set_ciphersuites("TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256")
      .unwrap();
   tls.set_min_proto_version(Some(openssl::ssl::SslVersion::TLS1_3)).unwrap();
   tls.set_verify(openssl::ssl::SslVerifyMode::PEER | openssl::ssl::SslVerifyMode::FAIL_IF_NO_PEER_CERT);
   tls.set_session_id_context(cli.redir_domain.as_bytes()).unwrap();

   proxy.add_tls_with_settings(&cli.listen_ip_port, None, tls);
   server.add_service(proxy);

   server.run_forever();
}
