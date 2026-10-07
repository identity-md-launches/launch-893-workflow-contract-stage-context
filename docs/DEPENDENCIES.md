# Vendored dependencies

These files are included as ordinary source, with no submodules or install step:

| Dependency | Version | Included files | Source |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.1.0 | ERC20, IERC20, IERC20Metadata, Context, ERC-6093 errors, ReentrancyGuard, LICENSE | https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0 |
| forge-std | v1.9.6 | `src/` and both license files; tests only | https://github.com/foundry-rs/forge-std/tree/v1.9.6 |

Production OpenZeppelin source is unmodified and MIT licensed. forge-std is supplied under its included MIT/Apache licenses. The archive files, package manifests, CI files, nested repositories and compiler binaries are not included. Remappings are local.

The small `IVRFCoordinator` declaration is the project's ABI subset, not a vendored Chainlink proof verifier. Runtime proof verification resides in the configured external coordinator. Its static request struct and callback match the v2.5 subscription ABI. There is intentionally no inherited coordinator migration or owner surface.
