import { alphaMain, alphaHelper } from "@test/alpha"

export function betaMain() {
  return `beta wraps ${alphaMain()} with ${alphaHelper()}`
}
