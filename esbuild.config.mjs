import esbuild from "esbuild";
import process from "process";
import builtins from "builtin-modules";
import { copyFileSync, mkdirSync } from "fs";
import { join } from "path";

const prod = process.argv[2] === "production";
const outDir = process.env.LEARN_LOOP_OUT || "./dist";

mkdirSync(outDir, { recursive: true });

// manifest 與 styles 不經過編譯，直接複製到輸出目錄，Obsidian 才載得到
const copyStatic = () => {
	copyFileSync("manifest.json", join(outDir, "manifest.json"));
};

const context = await esbuild.context({
	entryPoints: ["src/main.ts"],
	bundle: true,
	external: ["obsidian", "electron", ...builtins],
	format: "cjs",
	target: "es2018",
	logLevel: "info",
	sourcemap: prod ? false : "inline",
	treeShaking: true,
	outfile: join(outDir, "main.js"),
	plugins: [
		{
			name: "copy-static",
			setup(build) {
				build.onEnd(copyStatic);
			},
		},
	],
});

if (prod) {
	await context.rebuild();
	process.exit(0);
} else {
	await context.watch();
}
