## Emits the JS wire-constants block (src/gridlock/wire_constants.nim) on
## stdout. The static replay bundle cannot run the server's splice, so
## Dockerfile.replay-viewer runs this to write dist/wire_constants.js —
## same constants, same source, different delivery.
import ../src/gridlock/wire_constants

echo WireConstantsJs
