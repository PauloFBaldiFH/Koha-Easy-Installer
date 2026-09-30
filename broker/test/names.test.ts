import { describe, expect, it } from "vitest";
import { hostnamesFor, maxSlugLength, slugCandidates, slugFromStaffHost, slugify, validateSlug } from "../src/names";

const cfg = { NAME_PREFIX: "t-", STAFF_SUFFIX: "-admin", ZONE_NAME: "bibliotecamunicipalpalotina.org" };
const opts = { prefix: "t-", staffSuffix: "-admin" };

describe("names", () => {
  it("slugifies Portuguese names", () => {
    expect(slugify("Biblioteca Pública Municipal de Palotina")).toBe("biblioteca-publica-municipal-de-palotina");
    expect(slugify("  São João -- PR ")).toBe("sao-joao-pr");
  });

  it("accepts ordinary names", () => {
    expect(validateSlug("palotina-pr", opts)).toEqual({ ok: true });
  });

  it("rejects reserved, malformed and too long names", () => {
    expect(validateSlug("www", opts).ok).toBe(false);
    expect(validateSlug("-abc", opts).ok).toBe(false);
    expect(validateSlug("ab", opts).ok).toBe(false);
    expect(validateSlug("xn--80ak6aa92e", opts).ok).toBe(false);
    expect(validateSlug("a".repeat(maxSlugLength("t-", "-admin") + 1), opts).ok).toBe(false);
    expect(validateSlug("palotina-admin", opts).ok).toBe(false);
  });

  it("blocks phishing words, including look-alikes, unless forced", () => {
    expect(validateSlug("caixa-login", opts).ok).toBe(false);
    expect(validateSlug("l0g1n-palotina", opts).ok).toBe(false);
    expect(validateSlug("rnicrosoft", opts).ok).toBe(false);
    expect(validateSlug("biblioteca-caixa", { ...opts, allowBlocked: true }).ok).toBe(true);
  });

  it("builds flat hostnames and maps staff hosts back to slugs", () => {
    const h = hostnamesFor("palotina-pr", cfg);
    expect(h).toEqual({
      opac: "t-palotina-pr.bibliotecamunicipalpalotina.org",
      staff: "t-palotina-pr-admin.bibliotecamunicipalpalotina.org",
    });
    expect(slugFromStaffHost(h.staff, cfg)).toBe("palotina-pr");
    expect(slugFromStaffHost(h.opac, cfg)).toBeNull();
    expect(slugFromStaffHost("koha-broker.bibliotecamunicipalpalotina.org", cfg)).toBeNull();
    expect(slugFromStaffHost("x-admin.other.org", cfg)).toBeNull();
  });

  it("lists automatic name candidates: requested, institution, then numbered", () => {
    const c = slugCandidates("Palotina PR", "Biblioteca Pública de Palotina", 20);
    expect(c.slice(0, 3)).toEqual(["palotina-pr", "palotina-pr-2", "palotina-pr-3"]);
    expect(c).toContain("biblioteca-publica-d");
    expect(c).toContain("biblioteca-publica-2");
    expect(c.every((x) => x.length <= 20 && !x.endsWith("-"))).toBe(true);
    expect(slugCandidates("", "Biblioteca", 20)[0]).toBe("biblioteca");
    expect(slugCandidates("", "", 20)).toEqual([]);
  });
});
