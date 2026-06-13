import { Container } from "@cloudflare/containers";

export class CursorSdkBridgeContainer extends Container {
  defaultPort = 8792;
  sleepAfter = "30m";
  pingEndpoint = "localhost/health";
  envVars = {
    CURSOR_SDK_BRIDGE_HOST: "0.0.0.0",
    CURSOR_SDK_BRIDGE_PORT: "8792",
  };
  enableInternet = true;
}
