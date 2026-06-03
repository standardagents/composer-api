import { register } from "node:module";

register(new URL("./hooks-cloudflare-mock.mjs", import.meta.url).href, import.meta.url);
