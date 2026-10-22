import { expect, test } from "vitest";
import { greet } from "./hello.ts";

test("greet", () => {
  expect(greet("world")).toBe("Hello, world!");
});
