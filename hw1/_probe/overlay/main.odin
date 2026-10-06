package probe

import "core:fmt"
import "core:math"
import "core:os"

// Overlays the circle where the shader's radiance equals 1.0 onto a render, so the
// predicted clipping boundary can be compared with what the render actually shows.
//
// The camera is the scene's own: eye (0, 0.34, 1.05), target (0, 0.23, 0), up +Y,
// fov_y 45 degrees, aspect from the image. The world-to-clip matrix is built here with the
// standard OpenGL perspective and look-at forms.
main :: proc() {
	W :: 1920
	H :: 1080

	eye := [3]f32{0.0, 0.34, 1.05}
	target := [3]f32{0.0, 0.23, 0.0}
	up := [3]f32{0.0, 1.0, 0.0}
	fov_y := f32(math.PI) * 0.25
	znear := f32(0.1)
	zfar := f32(1000.0)

	// Look-at, column major, right-handed, camera down -Z.
	f := target - eye
	fl := f32(math.sqrt(f64(f.x*f.x + f.y*f.y + f.z*f.z)))
	f = f / fl
	s := [3]f32{f.y*up.z - f.z*up.y, f.z*up.x - f.x*up.z, f.x*up.y - f.y*up.x}
	sl := f32(math.sqrt(f64(s.x*s.x + s.y*s.y + s.z*s.z)))
	s = s / sl
	u := [3]f32{s.y*f.z - s.z*f.y, s.z*f.x - s.x*f.z, s.x*f.y - s.y*f.x}

	view := [16]f32{
		s.x, u.x, -f.x, 0,
		s.y, u.y, -f.y, 0,
		s.z, u.z, -f.z, 0,
		-(s.x*eye.x + s.y*eye.y + s.z*eye.z),
		-(u.x*eye.x + u.y*eye.y + u.z*eye.z),
		(f.x*eye.x + f.y*eye.y + f.z*eye.z),
		1,
	}

	aspect := f32(W) / f32(H)
	t := f32(math.tan(f64(fov_y) * 0.5))
	proj := [16]f32{
		1.0 / (aspect * t), 0, 0, 0,
		0, 1.0 / t, 0, 0,
		0, 0, (zfar + znear) / (znear - zfar), -1,
		0, 0, (2 * zfar * znear) / (znear - zfar), 0,
	}

	mul :: proc(a, b: [16]f32) -> [16]f32 {
		r: [16]f32
		for c in 0 ..< 4 {
			for row in 0 ..< 4 {
				v: f32 = 0
				for k in 0 ..< 4 {
					v += a[k*4 + row] * b[c*4 + k]
				}
				r[c*4 + row] = v
			}
		}
		return r
	}
	vp := mul(proj, view)

	project :: proc(vp: [16]f32, p: [3]f32) -> (x, y: f32, visible: bool) {
		cx := vp[0]*p.x + vp[4]*p.y + vp[8]*p.z + vp[12]
		cy := vp[1]*p.x + vp[5]*p.y + vp[9]*p.z + vp[13]
		cw := vp[3]*p.x + vp[7]*p.y + vp[11]*p.z + vp[15]
		if cw <= 0.0001 {
			return 0, 0, false
		}
		ndc_x := cx / cw
		ndc_y := cy / cw
		return (ndc_x * 0.5 + 0.5) * f32(W), (1.0 - (ndc_y * 0.5 + 0.5)) * f32(H), true
	}

	lp := [3]f32{0.55, 0.8, 0.55}
	floor_y: f32 = -0.02825936
	h := lp.y - floor_y
	intensity: f32 = 2.4

	radiance_at :: proc(h, intensity, r: f32) -> f32 {
		d := f32(math.sqrt(f64(h*h + r*r)))
		return intensity * ((h / d) * 0.5 + 0.5) / (d * d)
	}

	radius_at :: proc(h, intensity, level: f32) -> f32 {
		lo: f32 = 0
		hi: f32 = 50
		for _ in 0 ..< 80 {
			r := (lo + hi) * 0.5
			if radiance_at(h, intensity, r) > level {
				lo = r
			} else {
				hi = r
			}
		}
		return lo
	}

	// Mark the circle's samples onto the render.
	data, err := os.read_entire_file_from_path("_probe\\restored2.png", context.allocator)
	if err != nil {
		fmt.eprintln("cannot read the render:", err)
		return
	}
	defer delete(data)
	fmt.println("read the render,", len(data), "bytes; PNG decoding is not available here,")
	fmt.println("so the projection is printed as coordinates instead of drawn.")
	fmt.println()

	fmt.println("the camera, and where the boundary circle lands in the image:")
	no_vis := 0
	for k in 0 ..< 72 {
		ang := f32(k) / 72.0 * 2.0 * math.PI
		r := radius_at(h, intensity, 1.0)
		p := [3]f32{lp.x + r*f32(math.cos(f64(ang))), floor_y, lp.z + r*f32(math.sin(f64(ang)))}
		sx, sy, vis := project(vp, p)
		if !vis {
			no_vis += 1
			continue
		}
		on_screen := sx >= 0 && sx < f32(W) && sy >= 0 && sy < f32(H)
		if !on_screen {
			continue
		}
		fmt.println(
			"   angle", int(ang * 180.0 / f32(math.PI)), "deg  world (", p.x, ",", p.z, ")",
			"  screen (", int(sx), ",", int(sy), ")",
		)
	}
	fmt.println()
	fmt.println("   points behind the camera:", no_vis)
}
