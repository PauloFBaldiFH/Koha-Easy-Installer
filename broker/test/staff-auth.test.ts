import { describe, expect, it } from "vitest";
import { pbkdf2, randomBytes, toBase64 } from "../src/crypto";
import { checkPassword, getCookie, makeSession, parseBasicAuth, verifySession } from "../src/staff-auth";

describe("staff edge gate helpers", () => {
  it("parses Basic Auth, including colons in the password", () => {
    expect(parseBasicAuth(`Basic ${btoa("ana:pa:ss")}`)).toEqual({ user: "ana", pass: "pa:ss" });
    expect(parseBasicAuth("Bearer x")).toBeNull();
    expect(parseBasicAuth(`Basic ${btoa("nocolon")}`)).toBeNull();
    expect(parseBasicAuth(null)).toBeNull();
  });

  it("checks PBKDF2 passwords", async () => {
    const salt = randomBytes(16);
    const lib = {
      staff_user: "biblioteca",
      staff_pass_hash: await pbkdf2("correct horse battery", salt, 1000),
      staff_pass_salt: toBase64(salt),
      staff_pass_iter: 1000,
    };
    expect(await checkPassword(lib, "biblioteca", "correct horse battery")).toBe(true);
    expect(await checkPassword(lib, "biblioteca", "wrong")).toBe(false);
    expect(await checkPassword(lib, "other", "correct horse battery")).toBe(false);
    expect(await checkPassword({ ...lib, staff_pass_hash: null }, "biblioteca", "correct horse battery")).toBe(false);
  });

  it("issues sessions bound to host, library and credential version", async () => {
    const key = "k".repeat(40);
    const at = 1_800_000_000;
    const v = await makeSession(key, "t-a-admin.example.org", "lib1", 3, at);
    expect(await verifySession(key, v, "t-a-admin.example.org", "lib1", 3, at + 60)).toBe(true);
    expect(await verifySession(key, v, "t-b-admin.example.org", "lib1", 3, at + 60)).toBe(false);
    expect(await verifySession(key, v, "t-a-admin.example.org", "lib2", 3, at + 60)).toBe(false);
    expect(await verifySession(key, v, "t-a-admin.example.org", "lib1", 4, at + 60)).toBe(false);
    expect(await verifySession(key, v, "t-a-admin.example.org", "lib1", 3, at + 13 * 3600)).toBe(false);
    expect(await verifySession("x".repeat(40), v, "t-a-admin.example.org", "lib1", 3, at + 60)).toBe(false);
  });

  it("reads cookies", () => {
    expect(getCookie("a=1; __Host-kei_staff=x.y.z; b=2", "__Host-kei_staff")).toBe("x.y.z");
    expect(getCookie(null, "a")).toBeNull();
  });
});
