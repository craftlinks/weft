// Runs the regress wasm and prints its text. All the checking is in regress.zig.
import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]));
const { memory, regress_render, regress_text } = instance.exports;
const size = regress_render();
process.stdout.write(new Uint8Array(memory.buffer, regress_text(), size));
