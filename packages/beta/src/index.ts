import { alphaMain, alphaHelper } from "@test/alpha"
import { ALPHA_VERSION } from "@test/alpha/config"

export function betaMain() {
  return `beta-v2 wraps ${alphaMain()} with ${alphaHelper()} (${ALPHA_VERSION})`
}
