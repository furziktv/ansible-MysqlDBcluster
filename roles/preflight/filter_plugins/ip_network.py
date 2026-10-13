"""Small IPv4/CIDR filters based only on Python's standard library."""

from __future__ import annotations

import ipaddress


def ipv4_address_valid(value: object) -> bool:
    try:
        ipaddress.IPv4Address(str(value))
        return True
    except (ipaddress.AddressValueError, TypeError, ValueError):
        return False


def ip_cidr_valid(value: object) -> bool:
    """Accept IPv4 or IPv6 interface notation, including host bits in CIDRs."""
    try:
        ipaddress.ip_interface(str(value))
        return True
    except (ipaddress.AddressValueError, ipaddress.NetmaskValueError, TypeError, ValueError):
        return False


def ipv4_in_cidr(address: object, cidr: object) -> bool:
    try:
        parsed_address = ipaddress.IPv4Address(str(address))
        network = ipaddress.IPv4Network(str(cidr), strict=False)
        return parsed_address in network
    except (ipaddress.AddressValueError, ipaddress.NetmaskValueError, TypeError, ValueError):
        return False


def ipv4_cidr_prefix(cidr: object) -> int | None:
    try:
        return ipaddress.IPv4Network(str(cidr), strict=False).prefixlen
    except (ipaddress.AddressValueError, ipaddress.NetmaskValueError, TypeError, ValueError):
        return None


class FilterModule:
    def filters(self) -> dict[str, object]:
        return {
            "ipv4_address_valid": ipv4_address_valid,
            "ip_cidr_valid": ip_cidr_valid,
            "ipv4_in_cidr": ipv4_in_cidr,
            "ipv4_cidr_prefix": ipv4_cidr_prefix,
        }
