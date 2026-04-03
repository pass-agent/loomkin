/**
 * Deep readonly utility type.
 * Applies `readonly` recursively to all non-function properties of T.
 * Function properties are kept callable (not wrapped in Immutable).
 * Primitive values are returned as-is.
 */
export type Immutable<T> = {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  readonly [K in keyof T]: T[K] extends (...args: any[]) => any
    ? T[K]
    : T[K] extends object
      ? Immutable<T[K]>
      : T[K];
};
