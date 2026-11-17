# -*- mode: python; python-indent: 4 -*-
import ncs
from ncs.application import Service


def compute_qos(bandwidth_kbps, burst=None, peak_burst=None):
    """Return (police_rate_bps, shape_rate_bps, burst_bytes, peak_burst_bytes)."""
    rate_bps = int(bandwidth_kbps) * 1000
    burst_bytes = int(burst) if burst is not None else rate_bps * 3 // 16
    peak_burst_bytes = int(peak_burst) if peak_burst is not None else 2 * burst_bytes
    return rate_bps, rate_bps, burst_bytes, peak_burst_bytes


class ServiceCallbacks(Service):

    @Service.create
    def cb_create(self, tctx, root, service, proplist):
        self.log.info('Service create(service=', service._path, ')')

        vrf = service.vrf
        qos = service.qos
        intf = service.interface
        ipv6_enable = bool(service.ipv6_enable)

        police_rate, shape_rate, burst, peak_burst = compute_qos(
            service.bandwidth, qos.burst, qos.peak_burst)

        vars = ncs.template.Variables()
        vars.add('DEVICE', service.device_name)
        vars.add('IPV6_ENABLE', 'true' if ipv6_enable else 'false')
        vars.add('BGP_AS', service.bgp_as)
        vars.add('BANDWIDTH', service.bandwidth)
        vars.add('VRF_NAME', vrf.vrf_name)
        vars.add('RD_VALUE', vrf.rd_value)
        vars.add('MAX_PREFIX', vrf.maximum_prefix.limit)
        vars.add('THRESHOLD', vrf.maximum_prefix.threshold)
        vars.add('IN_POLICY_NAME', qos.in_policy_name)
        vars.add('OUT_POLICY_NAME', qos.out_policy_name)
        vars.add('MPLS_EXP', qos.mpls_exp)
        vars.add('POLICE_RATE_BPS', police_rate)
        vars.add('SHAPE_RATE_BPS', shape_rate)
        vars.add('BURST_BYTES', burst)
        vars.add('PEAK_BURST_BYTES', peak_burst)
        vars.add('INTERFACE_TYPE', intf.interface_type)
        vars.add('SUBINTF_FULL_ID', f'{intf.interface_id}.{intf.subintf_id}')
        vars.add('DESCRIPTION', intf.description or '')
        vars.add('SVLAN', intf.svlan)
        vars.add('CVLAN', intf.cvlan)
        vars.add('IP_ADDRESS', intf.ip_address)
        vars.add('SUBNET_MASK', intf.subnet_mask)
        vars.add('IPV6_ADDRESS', intf.ipv6_address if ipv6_enable else '')

        template = ncs.template.Template(service)
        template.apply('l3vpn-ai-template', vars)


class Main(ncs.application.Application):
    def setup(self):
        self.log.info('Main RUNNING')
        self.register_service('l3vpn-ai-servicepoint', ServiceCallbacks)

    def teardown(self):
        self.log.info('Main FINISHED')
