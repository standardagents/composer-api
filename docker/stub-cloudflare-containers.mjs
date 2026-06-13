/** Stub used by the self-hosted API server so worker/index.ts can load without Cloudflare Containers. */
export class Container {
  defaultPort = 8792;
  sleepAfter = "30m";
  pingEndpoint = "localhost/health";
  envVars = {};
  enableInternet = true;
}
