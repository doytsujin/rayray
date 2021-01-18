const std = @import("std");

const c = @import("c.zig");
const shaderc = @import("shaderc.zig");

const Blit = @import("blit.zig").Blit;
const Preview = @import("preview.zig").Preview;
const Scene = @import("scene.zig").Scene;
const Options = @import("options.zig").Options;
const Viewport = @import("viewport.zig").Viewport;

pub const Renderer = struct {
    const Self = @This();

    initialized: bool = false,

    device: c.WGPUDeviceId,
    queue: c.WGPUQueueId,

    scene: Scene,

    // We accumulate rays into this texture, then blit it to the screen
    tex: c.WGPUTextureId,
    tex_view: c.WGPUTextureViewId,

    preview: Preview,
    blit: Blit,

    uniforms: c.rayUniforms,
    uniform_buf: c.WGPUBufferId,

    start_time_ms: i64,
    frame: u64,

    pub fn init(
        alloc: *std.mem.Allocator,
        scene: Scene,
        options: Options,
        device: c.WGPUDeviceId,
    ) !Self {
        ////////////////////////////////////////////////////////////////////////
        // Uniform buffers (shared by both raytracing and blitter)
        const uniform_buf = c.wgpu_device_create_buffer(
            device,
            &(c.WGPUBufferDescriptor){
                .label = "blit uniforms",
                .size = @sizeOf(c.rayUniforms),
                .usage = c.WGPUBufferUsage_UNIFORM | c.WGPUBufferUsage_COPY_DST,
                .mapped_at_creation = false,
            },
        );

        var out = Renderer{
            .device = device,
            .queue = c.wgpu_device_get_default_queue(device),

            .preview = try Preview.init(alloc, scene, device, uniform_buf),
            .blit = undefined, // Built after resize()
            .scene = scene,

            // Populated in update_size()
            .tex = undefined,
            .tex_view = undefined,

            .uniforms = .{
                // Populated in update_size()
                .width_px = undefined,
                .height_px = undefined,

                .samples = 0,
                .samples_per_frame = options.samples_per_frame,

                .camera = scene.camera,
            },
            .uniform_buf = uniform_buf,

            .start_time_ms = 0,
            .frame = 0,
        };
        out.update_size(options.width, options.height);
        out.blit = try Blit.init(alloc, device, out.tex_view, uniform_buf);
        out.initialized = true;

        return out;
    }

    pub fn get_options(self: *const Self) Options {
        return .{
            .samples_per_frame = self.uniforms.samples_per_frame,
            .width = self.uniforms.width_px,
            .height = self.uniforms.height_px,
        };
    }

    fn update_uniforms(self: *const Self) void {
        c.wgpu_queue_write_buffer(
            self.queue,
            self.uniform_buf,
            0,
            @ptrCast([*c]const u8, &self.uniforms),
            @sizeOf(c.rayUniforms),
        );
    }

    fn draw_camera_gui(self: *Self) bool {
        const ui_changed = [_]bool{
            c.igDragFloat3("pos", @ptrCast([*c]f32, &self.uniforms.camera.pos), 0.05, -10, 10, "%.1f", 0),
            c.igDragFloat3("target", @ptrCast([*c]f32, &self.uniforms.camera.target), 0.05, -10, 10, "%.1f", 0),
            c.igDragFloat3("up", @ptrCast([*c]f32, &self.uniforms.camera.up), 0.1, -1, 1, "%.1f", 0),
            c.igDragFloat("perspective", &self.uniforms.camera.perspective, 0.01, 0, 1, "%.2f", 0),
            c.igDragFloat("defocus", &self.uniforms.camera.defocus, 0.001, 0, 0.2, "%.2f", 0),
            c.igDragFloat("focal length", &self.uniforms.camera.focal_distance, 0.01, 0, 10, "%.2f", 0),
            c.igDragFloat("scale", &self.uniforms.camera.scale, 0.05, 0, 2, "%.1f", 0),
        };
        var changed = false;
        for (ui_changed) |b| {
            changed = b or changed;
        }
        const w = c.igGetWindowWidth() - c.igGetCursorPosX();
        c.igIndent(w * 0.25);
        if (c.igButton("Reset", .{ .x = w * 0.5, .y = 0 })) {
            self.uniforms.camera = self.scene.camera;
            changed = true;
        }
        c.igUnindent(w * 0.25);
        return changed;
    }

    pub fn draw_gui(self: *Self, menu_height: f32, menu_width: *f32) !void {
        var changed = false;

        c.igPushStyleVarFloat(c.ImGuiStyleVar_WindowRounding, 0.0);
        c.igPushStyleVarFloat(c.ImGuiStyleVar_WindowBorderSize, 1.0);
        c.igSetNextWindowPos(.{ .x = 0, .y = menu_height }, c.ImGuiCond_Always, .{ .x = 0, .y = 0 });
        const window_size = c.igGetIO().*.DisplaySize;
        c.igSetNextWindowSizeConstraints(.{
            .x = 0,
            .y = window_size.y - menu_height,
        }, .{
            .x = window_size.x / 2,
            .y = window_size.y - menu_height,
        }, null, null);
        const flags = c.ImGuiWindowFlags_NoTitleBar |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoCollapse;
        if (c.igBegin("rayray", null, flags)) {
            if (c.igCollapsingHeaderBoolPtr("Camera", null, 0)) {
                changed = self.draw_camera_gui() or changed;
            }

            if (c.igCollapsingHeaderBoolPtr("Shapes", null, 0)) {
                changed = (try self.scene.draw_shapes_gui()) or changed;
            }

            if (c.igCollapsingHeaderBoolPtr("Materials", null, 0)) {
                changed = (try self.scene.draw_materials_gui()) or changed;
            }
            menu_width.* = c.igGetWindowWidth();
        }

        c.igEnd();
        c.igPopStyleVar(2);

        if (changed) {
            try self.preview.upload_scene(self.scene);
            self.uniforms.samples = 0;
        }
    }

    pub fn draw(
        self: *Self,
        viewport: Viewport,
        next_texture: c.WGPUSwapChainOutput,
        cmd_encoder: c.WGPUCommandEncoderId,
    ) !void {
        const width = @floatToInt(u32, viewport.width);
        const height = @floatToInt(u32, viewport.height);
        if (width != self.uniforms.width_px or height != self.uniforms.height_px) {
            self.update_size(width, height);
        }

        self.update_uniforms();

        // Record the start time at the first frame, to skip startup time
        if (self.uniforms.samples == 0) {
            self.start_time_ms = std.time.milliTimestamp();
        }

        // Cast another set of rays, one per pixel
        try self.preview.draw(self.uniforms.samples == 0, self.tex_view, cmd_encoder);
        self.uniforms.samples += self.uniforms.samples_per_frame;
        self.frame += 1;

        self.blit.draw(viewport, next_texture, cmd_encoder);
    }

    fn prefix(v: *f64) u8 {
        if (v.* > 1_000_000_000) {
            v.* /= 1_000_000_000;
            return 'G';
        } else if (v.* > 1_000_000) {
            v.* /= 1_000_000;
            return 'M';
        } else if (v.* > 1_000) {
            v.* /= 1_000;
            return 'K';
        } else {
            return ' ';
        }
    }

    pub fn stats(self: *const Self, alloc: *std.mem.Allocator) ![]u8 {
        var ray_count = @intToFloat(f64, self.uniforms.width_px) *
            @intToFloat(f64, self.uniforms.height_px) *
            @intToFloat(f64, self.uniforms.samples);

        const dt_sec = @intToFloat(f64, std.time.milliTimestamp() - self.start_time_ms) / 1000.0;

        var rays_per_sec = ray_count / dt_sec;
        var rays_per_sec_prefix = prefix(&rays_per_sec);

        return try std.fmt.allocPrintZ(
            alloc,
            "{d:.2} {c}ray/sec | {} rays/pixel | {} x {}",
            .{
                rays_per_sec,
                rays_per_sec_prefix,
                self.uniforms.samples,
                self.uniforms.width_px,
                self.uniforms.height_px,
            },
        );
    }

    pub fn deinit(self: *Self) void {
        self.blit.deinit();
        self.preview.deinit();
        self.scene.deinit();
        self.destroy_textures();
        c.wgpu_buffer_destroy(self.uniform_buf);
    }

    fn destroy_textures(self: *Self) void {
        c.wgpu_texture_destroy(self.tex);
        c.wgpu_texture_view_destroy(self.tex_view);
    }

    pub fn update_size(self: *Self, width: u32, height: u32) void {
        if (self.initialized) {
            self.destroy_textures();
        }
        self.tex = c.wgpu_device_create_texture(
            self.device,
            &(c.WGPUTextureDescriptor){
                .size = .{
                    .width = width,
                    .height = height,
                    .depth = 1,
                },
                .mip_level_count = 1,
                .sample_count = 1,
                .dimension = c.WGPUTextureDimension._D2,
                .format = c.WGPUTextureFormat._Rgba32Float,

                // We render to this texture, then use it as a source when
                // blitting into the final UI image
                .usage = (c.WGPUTextureUsage_OUTPUT_ATTACHMENT |
                    c.WGPUTextureUsage_SAMPLED),
                .label = "raytrace_tex",
            },
        );
        self.tex_view = c.wgpu_texture_create_view(
            self.tex,
            &(c.WGPUTextureViewDescriptor){
                .label = "raytrace_tex_view",
                .dimension = c.WGPUTextureViewDimension._D2,
                .format = c.WGPUTextureFormat._Rgba32Float,
                .aspect = c.WGPUTextureAspect._All,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .array_layer_count = 1,
            },
        );

        self.uniforms.width_px = width;
        self.uniforms.height_px = height;
        self.uniforms.samples = 0;

        self.start_time_ms = std.time.milliTimestamp();

        if (self.initialized) {
            self.blit.bind(self.tex_view, self.uniform_buf);
        }
    }
};
