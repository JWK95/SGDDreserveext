// Builds test export strings, exactly the way the website will have to.
//
// This is not a mock of the format -- it IS the format, and it is here so the
// addon can be tested before the website's half exists. It also doubles as the
// reference the other repo's implementation must agree with: if their output
// and this script's output differ for the same rows, one of them is wrong.
//
//   node spec/fixtures/generate.mjs "Talithmusher-TwistingNether"
//
// Pass the character you will be logged in as, exactly as
//   /run print(UnitName("player") .. "-" .. GetNormalizedRealmName())
// prints it in game. Without that the officer column has nobody to match.

import { deflateRawSync, inflateRawSync } from "node:zlib";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

const GUILD = "Same Gear Different Day";

// Well-known item ids that exist in the retail item database, so the client
// resolves real links and the tooltips are worth looking at. The exported names
// below are only the cold-cache fallback -- the addon shows whatever the client
// says the id is.
const ITEMS = {
	19019: "Thunderfury",
	17182: "Sulfuras",
	22691: "Corrupted Ashbringer",
	12590: "Felstriker",
	18832: "Brutality Blade",
	17204: "Eye of Sulfuras",
};

const you = process.argv[2] || "Talithmusher-TwistingNether";
const [youName, youRealm] = [you.slice(0, you.indexOf("-")), you.slice(you.indexOf("-") + 1)];

// The website emits the realm twice: the in-game form and its own slug. Derive a
// plausible slug from the in-game form so the fixture exercises both.
const slug = youRealm.replace(/([a-z])([A-Z])/g, "$1-$2").toLowerCase();

const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const ago = (days) =>
	new Date(Date.now() - days * 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");

function encode(lines) {
	return "SGDDR:1:" + deflateRawSync(Buffer.from(lines.join("\n"), "utf8")).toString("base64");
}

function header(kind) {
	return [`V|1|0`, `K|${kind}`, `G|${GUILD}`, `T|${now}`];
}

const S = (key, id, tier, when) => `S|${key}|${id}|${tier}|${when}|${ITEMS[id]}`;
const A = (key, id, tier, when) => `A|${key}|${id}|${tier}|${when}|${ITEMS[id]}`;
const C = (key, name, realmSlug, cls) => `C|${key}|${name}|${realmSlug}|${cls}`;

// Other guild members, on deliberately awkward realms: a multi-word one and an
// apostrophe one, because those are what break the key fold.
const OTHERS = [
	{ key: "Beefy-ArgentDawn", name: "Beefy", slug: "argent-dawn", cls: "WARRIOR" },
	{ key: "Zoe-TwistingNether", name: "Zoe", slug: "twisting-nether", cls: "EVOKER" },
	{ key: "Grimtusk-Kiljaeden", name: "Grimtusk", slug: "kiljaeden", cls: "DEATHKNIGHT" },
];

// An alt of YOURS, used by the mismatch fixture.
const ALT = { key: `${youName}alt-${youRealm}`, name: `${youName}alt`, slug, cls: "PRIEST" };

//------------------------------------------------------------------------------

const officer = encode([
	...header("officer"),
	C(you, youName, slug, "PALADIN"),
	...OTHERS.map((o) => C(o.key, o.name, o.slug, o.cls)),

	// You reserve three of the six, so the column shows hits and blanks side by
	// side -- a column that lights up for everything proves nothing.
	S(you, 19019, "Mythic", ago(3)),
	S(you, 17182, "Mythic", ago(3)),
	S(you, 22691, "Heroic", ago(2)),

	S("Beefy-ArgentDawn", 19019, "Heroic", ago(4)),
	S("Beefy-ArgentDawn", 12590, "Normal", ago(4)),
	S("Zoe-TwistingNether", 19019, "Mythic", ago(1)),
	S("Grimtusk-Kiljaeden", 18832, "Mythic", ago(5)),

	// Awarded rows: must appear ONLY in the /sgddr Awarded tab, never in the
	// loot table. If one of these shows up in the SR column, that is a bug.
	A("Beefy-ArgentDawn", 17204, "Heroic", ago(6)),
	A("Zoe-TwistingNether", 12590, "", ago(9)),
]);

const personalMatch = encode([
	...header("personal"),
	C(you, youName, slug, "PALADIN"),
	C(ALT.key, ALT.name, ALT.slug, ALT.cls),
	S(you, 19019, "Mythic", ago(3)),
	S(you, 17182, "Mythic", ago(3)),
	S(you, 22691, "Heroic", ago(2)),
	S(ALT.key, 12590, "Heroic", ago(3)),
]);

// Account-wide, and YOU are not on it. This is the fixture for the wrong-
// character warning: the addon can only say "you reserved on X, you are on Y"
// because the personal export carries the whole account.
const personalMismatch = encode([
	...header("personal"),
	C(ALT.key, ALT.name, ALT.slug, ALT.cls),
	S(ALT.key, 19019, "Mythic", ago(3)),
	S(ALT.key, 17182, "Mythic", ago(3)),
	S(ALT.key, 12590, "Heroic", ago(2)),
]);

const out = { officer, "personal-match": personalMatch, "personal-mismatch": personalMismatch };

mkdirSync(HERE, { recursive: true });
for (const [name, value] of Object.entries(out)) {
	writeFileSync(`${HERE}/${name}.txt`, value + "\n");
	console.log(`\n=== ${name} (${value.length} chars) ===\n${value}`);
}

// Also drop the officer PAYLOAD in the clear, for the Lua round-trip check and
// for anyone who wants to read what is actually in the blob.
writeFileSync(
	`${HERE}/officer.payload.txt`,
	Buffer.from(
		inflateRawSync(Buffer.from(officer.slice(8), "base64"))
	).toString("utf8")
);
