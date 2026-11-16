/** Reads the wall clock (epoch ms). A function, so every call reads again. */
export type GetNow = () => number;

/** Production GetNow. Only ever the default of an injectable time: `x ?? systemNow()` or `getNow ?? systemNow`. */
export const systemNow: GetNow = () => Date.now();
