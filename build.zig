const std = @import("std");
const package_manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `no-cli` skips the minizign command line tool and its zig-clap dependency.
    const minizign = b.dependency("minizign", .{ .target = target, .optimize = optimize, .@"no-cli" = true });

    const zigtui = b.dependency("zigtui", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("zigup", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "version", .module = createVersionModule(b) },
            .{ .name = "minizign", .module = minizign.module("minizign") },
            .{ .name = "zigtui", .module = zigtui.module("zigtui") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zigup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigup", .module = mod },
            },
        }),
    });

    exe.root_module.addImport("zigtui", zigtui.module("zigtui"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

/// The `version` module: `version` from build.zig.zon and `git_revision` of
/// the source tree. The revision comes from a step that runs on every build;
/// a value computed directly in build() would go stale, because the
/// configure phase is cached across commits.
fn createVersionModule(b: *std.Build) *std.Build.Module {
    const generate_version_source = b.addSystemCommand(&.{
        "sh", "-c",
        \\revision=${2:-$(git describe --always --dirty --abbrev=12 2>/dev/null || echo unknown)}
        \\printf 'pub const version = "%s";\npub const git_revision = "%s";\n' "$1" "$revision"
        ,
        "sh", package_manifest.version,
    });
    // Nix and tarball builds have no .git directory: -Dgit-revision=<rev>.
    if (b.option([]const u8, "git-revision", "Git revision to embed instead of running git describe")) |git_revision|
        generate_version_source.addArg(git_revision);
    generate_version_source.setCwd(b.path("."));
    generate_version_source.has_side_effects = true;
    const version_source = generate_version_source.captureStdOut(.{ .basename = "version.zig" });
    return b.createModule(.{ .root_source_file = version_source });
}
