const stubUrl = new URL("./stub-cloudflare-containers.mjs", import.meta.url)
  .href;

export async function resolve(specifier, context, nextResolve) {
  if (specifier === "@cloudflare/containers") {
    return { url: stubUrl, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}
