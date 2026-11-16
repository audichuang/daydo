import { createServerHlcClock } from './hlc';

/** Process-wide (per isolate) monotonic server HLC clock shared by sync push and MCP writers. */
export const serverClock = createServerHlcClock();
