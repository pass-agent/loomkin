/**
 * Deep readonly utility type.
 * Applies `readonly` recursively to all properties of T.
 * Primitive values are returned as-is.
 */
export type Immutable<T> = {
  readonly [K in keyof T]: T[K] extends object ? Immutable<T[K]> : T[K];
};
