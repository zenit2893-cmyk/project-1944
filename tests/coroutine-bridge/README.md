# Coroutine bridge regression entry point

The production bridge tests live beside the integration target so they build
with the pinned ReXGlue SDK and its Windows ABI. Run the checked-in entry point
from the workspace root:

```powershell
.\tests\coroutine-bridge\run.ps1
```

The runner delegates to `integration/coroutines/Run-Tests.ps1`, then checks the
recorded receipt for a successful exit code, 32 independent reference states,
two yield cycles, and both bridge-owned and SDK-borrowed root modes. The
receipt describes synthetic fixtures only; it does not represent a live game
launch or gameplay validation.
