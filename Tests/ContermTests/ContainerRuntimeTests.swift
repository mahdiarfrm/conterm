import Foundation
import Testing
@testable import Conterm

/// The container verbs are typed straight at a remote CLI, so the mapping from
/// action to command line is the part that has to be right — a wrong verb is a
/// button that does nothing, or worse, does something else.
struct ContainerRuntimeTests {
    @Test func dockerFamilySharesOneCliSurface() {
        for runtime in [ContainerRuntime.docker, .podman, .nerdctl] {
            #expect(runtime.command(.start, container: "web") == "\(runtime.tool) start 'web'")
            #expect(runtime.command(.stop, container: "web") == "\(runtime.tool) stop 'web'")
            #expect(runtime.command(.restart, container: "web") == "\(runtime.tool) restart 'web'")
            #expect(runtime.command(.remove, container: "web") == "\(runtime.tool) rm -f 'web'")
        }
    }

    @Test func appleContainerUsesItsOwnVerbs() {
        // `rm` is Docker's; Apple's CLI deletes.
        #expect(ContainerRuntime.apple.command(.remove, container: "web") == "container delete 'web'")
        // No restart of its own, so it is composed rather than dropped.
        #expect(ContainerRuntime.apple.command(.restart, container: "web")
                == "container stop 'web' && container start 'web'")
    }

    @Test func statsIsOfferedOnlyWhereItExists() {
        #expect(ContainerRuntime.docker.supports(.stats))
        #expect(!ContainerRuntime.apple.supports(.stats))
        // Everything else is answerable by every runtime.
        for action in ContainerAction.allCases where action != .stats {
            #expect(ContainerRuntime.apple.supports(action))
        }
    }

    @Test func logsFoldStderrIn() {
        // A container that logs to stderr would otherwise read as silent, since
        // only stdout comes back over the capture.
        #expect(ContainerRuntime.docker.command(.logs, container: "web")?.contains("2>&1") == true)
        #expect(ContainerRuntime.apple.command(.logs, container: "web")?.contains("2>&1") == true)
    }

    @Test func namesAreQuotedAgainstTheRemoteShell() {
        let line = ContainerRuntime.docker.command(.stop, container: "we'b; rm -rf /")
        #expect(line == #"docker stop 'we'\''b; rm -rf /'"#)
    }

    @Test func onlyRemoveIsDestructive() {
        #expect(ContainerAction.remove.isDestructive)
        for action in ContainerAction.allCases where action != .remove {
            #expect(!action.isDestructive)
        }
    }

    @Test func parsesStatsRow() {
        let s = ContainerControl.parseStats("12.34%\t118.2MiB / 7.667GiB\n")
        #expect(s?.cpu == "12.34%")
        #expect(s?.memory == "118.2MiB / 7.667GiB")
    }

    @Test func rejectsAStatsRowWithoutColumns() {
        #expect(ContainerControl.parseStats("") == nil)
        #expect(ContainerControl.parseStats("no tab here") == nil)
    }
}

/// A container's state drives which verb the bar offers, and the two runtimes
/// word it differently — Docker narrates ("Up 3 hours"), Apple states it.
struct ContainerStateTests {
    private func container(_ status: String) -> HostInfo.Container {
        HostInfo.Container(name: "c", image: "i", status: status)
    }

    @Test func readsBothWordingsOfRunning() {
        #expect(container("Up 3 hours").running)
        #expect(container("Up 2 days (healthy)").running)
        #expect(container("running").running)
    }

    @Test func everythingElseIsStopped() {
        #expect(!container("Exited (0) 2 days ago").running)
        #expect(!container("Created").running)
        #expect(!container("stopped").running)
        #expect(!container("").running)
    }
}

/// Which distribution a host reports decides the mark on its card. The names
/// overlap on purpose — Raspberry Pi OS, Kali and Proxmox all say "Debian"
/// somewhere — so the order of the matching is the behaviour worth pinning.
struct DistroDetectionTests {
    @Test func matchesTheDistributionsPrettyName() {
        #expect(Distro.detect("Ubuntu 24.04.1 LTS") == .ubuntu)
        #expect(Distro.detect("Debian GNU/Linux 12 (bookworm)") == .debian)
        #expect(Distro.detect("Fedora Linux 40 (Server Edition)") == .fedora)
        #expect(Distro.detect("Arch Linux") == .arch)
        #expect(Distro.detect("Alpine Linux v3.20") == .alpine)
        #expect(Distro.detect("NixOS 24.05 (Uakari)") == .nixos)
        #expect(Distro.detect("openSUSE Tumbleweed") == .suse)
        #expect(Distro.detect("Amazon Linux 2023") == .amazon)
    }

    @Test func derivativesBeatTheDistributionTheyAreBuiltOn() {
        #expect(Distro.detect("Debian GNU/Linux 12 (bookworm) Raspberry Pi") == .raspbian)
        #expect(Distro.detect("Kali GNU/Linux Rolling") == .kali)
        #expect(Distro.detect("Proxmox VE 8.2 / Debian 12") == .proxmox)
        #expect(Distro.detect("Linux Mint 21.3") == .mint)
        #expect(Distro.detect("Manjaro Linux") == .manjaro)
        #expect(Distro.detect("AlmaLinux 9.4 (Seafoam Ocelot)") == .alma)
    }

    @Test func readsTheEnterpriseFamilySeparately() {
        #expect(Distro.detect("Red Hat Enterprise Linux 9.4") == .rhel)
        #expect(Distro.detect("Rocky Linux 9.4") == .rocky)
        #expect(Distro.detect("CentOS Stream 9") == .centos)
    }

    @Test func readsAMacFromSwVers() {
        // The collector falls back to `sw_vers` where there is no os-release.
        #expect(Distro.detect("ProductName: macOS ProductVersion: 26.0") == .macos)
    }

    @Test func unknownAndEmptyKeepTheGenericGlyph() {
        #expect(Distro.detect(nil) == nil)
        #expect(Distro.detect("") == nil)
        #expect(Distro.detect("Some Vendor Appliance 4.2") == nil)
    }

    @Test func everyCaseIsNamed() {
        for d in Distro.allCases { #expect(!d.label.isEmpty) }
    }
}

/// The art is fetched by slug, so a typo is a mark that silently never arrives.
/// These were checked against the CDN when they were written; the point of
/// pinning them is that a later edit can't quietly break one.
struct DistroArtSlugTests {
    @Test func slugsMatchTheIconSet() {
        let expected: [Distro: String] = [
            .ubuntu: "ubuntu", .debian: "debian", .fedora: "fedora", .rhel: "redhat",
            .centos: "centos", .rocky: "rockylinux", .alma: "almalinux",
            .arch: "archlinux", .alpine: "alpinelinux", .suse: "opensuse",
            .nixos: "nixos", .gentoo: "gentoo", .manjaro: "manjaro",
            .raspbian: "raspberrypi", .kali: "kalilinux", .mint: "linuxmint",
            .proxmox: "proxmox", .openwrt: "openwrt", .freebsd: "freebsd",
        ]
        for (distro, slug) in expected { #expect(distro.iconSlug == slug) }
    }

    @Test func theTwoWithoutArtSaySo() {
        // Amazon Linux has no icon in the set; macOS already has `apple.logo`,
        // which ships with the system.
        #expect(Distro.amazon.iconSlug == nil)
        #expect(Distro.macos.iconSlug == nil)
    }

    @Test func everyOtherDistributionHasOne() {
        for d in Distro.allCases where d != .amazon && d != .macos {
            #expect(d.iconSlug?.isEmpty == false)
        }
    }
}
