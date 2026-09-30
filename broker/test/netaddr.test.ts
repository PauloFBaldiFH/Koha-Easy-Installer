import { describe, expect, it } from "vitest";
import { ipAllowed, parseCidr, parseIp } from "../src/netaddr";

describe("netaddr", () => {
  it("parses IPv4 and IPv6", () => {
    expect(parseIp("200.10.1.5")?.v).toBe(4);
    expect(parseIp("2804:14c::1")?.v).toBe(6);
    expect(parseIp("::1")?.n).toBe(1n);
    expect(parseIp("256.1.1.1")).toBeNull();
    expect(parseIp("1::2::3")).toBeNull();
    expect(parseIp("1:2:3:4:5:6:7")).toBeNull();
  });

  it("matches CIDR ranges", () => {
    expect(ipAllowed("200.10.1.5", ["200.10.0.0/16"])).toBe(true);
    expect(ipAllowed("200.11.1.5", ["200.10.0.0/16"])).toBe(false);
    expect(ipAllowed("2804:14c:1::9", ["2804:14c::/32"])).toBe(true);
    expect(ipAllowed("2804:14d::9", ["2804:14c::/32"])).toBe(false);
    expect(ipAllowed("10.0.0.1", ["10.0.0.1"])).toBe(true);
    expect(ipAllowed("10.0.0.1", ["2804:14c::/32"])).toBe(false);
  });

  it("rejects invalid ranges", () => {
    expect(parseCidr("10.0.0.0/33")).toBeNull();
    expect(parseCidr("10.0.0.0/x")).toBeNull();
    expect(parseCidr("nope")).toBeNull();
  });
});
