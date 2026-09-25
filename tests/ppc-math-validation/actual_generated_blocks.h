// Automatically extracted from real generated CoD3 C++.
// BSD-3-Clause ReXGlue generated patterns; see integration/ppc-math-validation/LICENSE.rexglue.
// Synthetic inputs only. No game assets, game execution, or dispatcher required.
#pragma once
#include <rex/ppc/context.h>
#include <cmath>
#include <climits>
namespace actual {
// cod3-pc\generated\default\cod3_pc_recomp.0.cpp:1520 sub_820D7070
__declspec(noinline) inline PPCVRegister vmadd(PPCVRegister a, PPCVRegister b, PPCVRegister c) {
  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};
  ctx.fpscr.InitHost();
  ctx.fpscr.enableFlushModeUnconditional();
  ctx.v2 = a; ctx.v10 = b; ctx.v9 = c;
	// vmaddfp v12,v2,v10,v9
	simde_mm_store_ps(ctx.v12.f32, simde_mm_add_ps(simde_mm_mul_ps(simde_mm_load_ps(ctx.v2.f32), simde_mm_load_ps(ctx.v10.f32)), simde_mm_load_ps(ctx.v9.f32)));
  return ctx.v12;
}
// cod3-pc\generated\default\cod3_pc_recomp.10.cpp:839 sub_820C4700
__declspec(noinline) inline PPCVRegister dot3(PPCVRegister a, PPCVRegister b) {
  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};
  ctx.fpscr.InitHost();
  ctx.fpscr.enableFlushModeUnconditional();
  ctx.v13 = a; ctx.v0 = b;
	// vmsum3fp128 v13,v13,v0
	ctx.fpscr.enableFlushMode();
	simde_mm_store_ps(ctx.v13.f32, simde_mm_dp_ps(simde_mm_load_ps(ctx.v13.f32), simde_mm_load_ps(ctx.v0.f32), 0xEF));
  return ctx.v13;
}
// cod3-pc\generated\default\cod3_pc_recomp.1.cpp:17765 sub_82363EF8
__declspec(noinline) inline PPCVRegister half4_alias(PPCVRegister a) {
  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};
  ctx.fpscr.InitHost();
  ctx.fpscr.enableFlushModeUnconditional();
  ctx.v0 = a;
	// vpkd3d128 v0,v0,5,2,2
	ctx.fpscr.enableFlushModeUnconditional();
	temp.u32 = (ctx.v0.u32[3]&0x7FFFFFFF);
	vTemp.u8[0] = (temp.f32 != temp.f32) || (temp.f32 > 65504.0f) ? 0xFF : ((ctx.v0.u32[3]&0x7f800000)>>23);
	temp.u16 = vTemp.u8[0] != 0xFF ? ((ctx.v0.u32[3]&0x7FE000)>>13) : 0x0;
	ctx.v0.u16[7] = vTemp.u8[0] != 0xFF ? (vTemp.u8[0] > 0x70 ? (((vTemp.u8[0]-0x70)<<10)+temp.u16) : (0x71-vTemp.u8[0] > 31 ? 0x0 : ((0x400+temp.u16)>>(0x71-vTemp.u8[0])))) : 0x7FFF;
	ctx.v0.u16[7] |= ((ctx.v0.u32[3]&0x80000000)>>16);
	temp.u32 = (ctx.v0.u32[2]&0x7FFFFFFF);
	vTemp.u8[0] = (temp.f32 != temp.f32) || (temp.f32 > 65504.0f) ? 0xFF : ((ctx.v0.u32[2]&0x7f800000)>>23);
	temp.u16 = vTemp.u8[0] != 0xFF ? ((ctx.v0.u32[2]&0x7FE000)>>13) : 0x0;
	ctx.v0.u16[6] = vTemp.u8[0] != 0xFF ? (vTemp.u8[0] > 0x70 ? (((vTemp.u8[0]-0x70)<<10)+temp.u16) : (0x71-vTemp.u8[0] > 31 ? 0x0 : ((0x400+temp.u16)>>(0x71-vTemp.u8[0])))) : 0x7FFF;
	ctx.v0.u16[6] |= ((ctx.v0.u32[2]&0x80000000)>>16);
	temp.u32 = (ctx.v0.u32[1]&0x7FFFFFFF);
	vTemp.u8[0] = (temp.f32 != temp.f32) || (temp.f32 > 65504.0f) ? 0xFF : ((ctx.v0.u32[1]&0x7f800000)>>23);
	temp.u16 = vTemp.u8[0] != 0xFF ? ((ctx.v0.u32[1]&0x7FE000)>>13) : 0x0;
	ctx.v0.u16[5] = vTemp.u8[0] != 0xFF ? (vTemp.u8[0] > 0x70 ? (((vTemp.u8[0]-0x70)<<10)+temp.u16) : (0x71-vTemp.u8[0] > 31 ? 0x0 : ((0x400+temp.u16)>>(0x71-vTemp.u8[0])))) : 0x7FFF;
	ctx.v0.u16[5] |= ((ctx.v0.u32[1]&0x80000000)>>16);
	temp.u32 = (ctx.v0.u32[0]&0x7FFFFFFF);
	vTemp.u8[0] = (temp.f32 != temp.f32) || (temp.f32 > 65504.0f) ? 0xFF : ((ctx.v0.u32[0]&0x7f800000)>>23);
	temp.u16 = vTemp.u8[0] != 0xFF ? ((ctx.v0.u32[0]&0x7FE000)>>13) : 0x0;
	ctx.v0.u16[4] = vTemp.u8[0] != 0xFF ? (vTemp.u8[0] > 0x70 ? (((vTemp.u8[0]-0x70)<<10)+temp.u16) : (0x71-vTemp.u8[0] > 31 ? 0x0 : ((0x400+temp.u16)>>(0x71-vTemp.u8[0])))) : 0x7FFF;
	ctx.v0.u16[4] |= ((ctx.v0.u32[0]&0x80000000)>>16);
  return ctx.v0;
}
// cod3-pc\generated\default\cod3_pc_recomp.35.cpp:8606 sub_82139D98
__declspec(noinline) inline PPCVRegister half2_alias(PPCVRegister a) {
  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};
  ctx.fpscr.InitHost();
  ctx.fpscr.enableFlushModeUnconditional();
  ctx.v0 = a;
	// vpkd3d128 v0,v0,3,2,2
	ctx.fpscr.enableFlushMode();
	temp.u32 = (ctx.v0.u32[3]&0x7FFFFFFF);
	vTemp.u8[0] = (temp.f32 != temp.f32) || (temp.f32 > 65504.0f) ? 0xFF : ((ctx.v0.u32[3]&0x7f800000)>>23);
	temp.u16 = vTemp.u8[0] != 0xFF ? ((ctx.v0.u32[3]&0x7FE000)>>13) : 0x0;
	ctx.v0.u16[5] = vTemp.u8[0] != 0xFF ? (vTemp.u8[0] > 0x70 ? (((vTemp.u8[0]-0x70)<<10)+temp.u16) : (0x71-vTemp.u8[0] > 31 ? 0x0 : ((0x400+temp.u16)>>(0x71-vTemp.u8[0])))) : 0x7FFF;
	ctx.v0.u16[5] |= ((ctx.v0.u32[3]&0x80000000)>>16);
	temp.u32 = (ctx.v0.u32[2]&0x7FFFFFFF);
	vTemp.u8[0] = (temp.f32 != temp.f32) || (temp.f32 > 65504.0f) ? 0xFF : ((ctx.v0.u32[2]&0x7f800000)>>23);
	temp.u16 = vTemp.u8[0] != 0xFF ? ((ctx.v0.u32[2]&0x7FE000)>>13) : 0x0;
	ctx.v0.u16[4] = vTemp.u8[0] != 0xFF ? (vTemp.u8[0] > 0x70 ? (((vTemp.u8[0]-0x70)<<10)+temp.u16) : (0x71-vTemp.u8[0] > 31 ? 0x0 : ((0x400+temp.u16)>>(0x71-vTemp.u8[0])))) : 0x7FFF;
	ctx.v0.u16[4] |= ((ctx.v0.u32[2]&0x80000000)>>16);
  return ctx.v0;
}
// cod3-pc\generated\default\cod3_pc_recomp.53.cpp:15173 sub_822EFAE8
__declspec(noinline) inline PPCVRegister half2_distinct(PPCVRegister a, PPCVRegister initial) {
  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};
  ctx.fpscr.InitHost();
  ctx.fpscr.enableFlushModeUnconditional();
  ctx.v1 = a; ctx.v0 = initial;
	// vpkd3d128 v0,v1,3,1,3
	ctx.fpscr.enableFlushMode();
	temp.u32 = (ctx.v1.u32[3]&0x7FFFFFFF);
	vTemp.u8[0] = (temp.f32 != temp.f32) || (temp.f32 > 65504.0f) ? 0xFF : ((ctx.v1.u32[3]&0x7f800000)>>23);
	temp.u16 = vTemp.u8[0] != 0xFF ? ((ctx.v1.u32[3]&0x7FE000)>>13) : 0x0;
	ctx.v0.u16[7] = vTemp.u8[0] != 0xFF ? (vTemp.u8[0] > 0x70 ? (((vTemp.u8[0]-0x70)<<10)+temp.u16) : (0x71-vTemp.u8[0] > 31 ? 0x0 : ((0x400+temp.u16)>>(0x71-vTemp.u8[0])))) : 0x7FFF;
	ctx.v0.u16[7] |= ((ctx.v1.u32[3]&0x80000000)>>16);
	temp.u32 = (ctx.v1.u32[2]&0x7FFFFFFF);
	vTemp.u8[0] = (temp.f32 != temp.f32) || (temp.f32 > 65504.0f) ? 0xFF : ((ctx.v1.u32[2]&0x7f800000)>>23);
	temp.u16 = vTemp.u8[0] != 0xFF ? ((ctx.v1.u32[2]&0x7FE000)>>13) : 0x0;
	ctx.v0.u16[6] = vTemp.u8[0] != 0xFF ? (vTemp.u8[0] > 0x70 ? (((vTemp.u8[0]-0x70)<<10)+temp.u16) : (0x71-vTemp.u8[0] > 31 ? 0x0 : ((0x400+temp.u16)>>(0x71-vTemp.u8[0])))) : 0x7FFF;
	ctx.v0.u16[6] |= ((ctx.v1.u32[2]&0x80000000)>>16);
  return ctx.v0;
}
// cod3-pc\generated\default\cod3_pc_recomp.20.cpp:11168 sub_82251D38
__declspec(noinline) inline PPCVRegister pack_unsigned_alias(PPCVRegister a, PPCVRegister b) {
  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};
  ctx.fpscr.InitHost();
  ctx.fpscr.enableFlushModeUnconditional();
  ctx.v0 = a; ctx.v13 = b;
	// vpkuhus v0,v0,v13
	ctx.v0.u8[15] = ctx.v0.u16[7] > 0xFF ? 0xFF : (uint8_t)ctx.v0.u16[7];
	ctx.v0.u8[7] = ctx.v13.u16[7] > 0xFF ? 0xFF : (uint8_t)ctx.v13.u16[7];
	ctx.v0.u8[14] = ctx.v0.u16[6] > 0xFF ? 0xFF : (uint8_t)ctx.v0.u16[6];
	ctx.v0.u8[6] = ctx.v13.u16[6] > 0xFF ? 0xFF : (uint8_t)ctx.v13.u16[6];
	ctx.v0.u8[13] = ctx.v0.u16[5] > 0xFF ? 0xFF : (uint8_t)ctx.v0.u16[5];
	ctx.v0.u8[5] = ctx.v13.u16[5] > 0xFF ? 0xFF : (uint8_t)ctx.v13.u16[5];
	ctx.v0.u8[12] = ctx.v0.u16[4] > 0xFF ? 0xFF : (uint8_t)ctx.v0.u16[4];
	ctx.v0.u8[4] = ctx.v13.u16[4] > 0xFF ? 0xFF : (uint8_t)ctx.v13.u16[4];
	ctx.v0.u8[11] = ctx.v0.u16[3] > 0xFF ? 0xFF : (uint8_t)ctx.v0.u16[3];
	ctx.v0.u8[3] = ctx.v13.u16[3] > 0xFF ? 0xFF : (uint8_t)ctx.v13.u16[3];
	ctx.v0.u8[10] = ctx.v0.u16[2] > 0xFF ? 0xFF : (uint8_t)ctx.v0.u16[2];
	ctx.v0.u8[2] = ctx.v13.u16[2] > 0xFF ? 0xFF : (uint8_t)ctx.v13.u16[2];
	ctx.v0.u8[9] = ctx.v0.u16[1] > 0xFF ? 0xFF : (uint8_t)ctx.v0.u16[1];
	ctx.v0.u8[1] = ctx.v13.u16[1] > 0xFF ? 0xFF : (uint8_t)ctx.v13.u16[1];
	ctx.v0.u8[8] = ctx.v0.u16[0] > 0xFF ? 0xFF : (uint8_t)ctx.v0.u16[0];
	ctx.v0.u8[0] = ctx.v13.u16[0] > 0xFF ? 0xFF : (uint8_t)ctx.v13.u16[0];
  return ctx.v0;
}
// cod3-pc\generated\default\cod3_pc_recomp.0.cpp:1687 sub_820E8CA0
__declspec(noinline) inline int64_t fctidz(double a) {
  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};
  ctx.fpscr.InitHost();
  ctx.fpscr.disableFlushModeUnconditional();
  ctx.f0.f64 = a;
	// fctidz f0,f0
	ctx.f0.s64 = std::isnan(ctx.f0.f64) ? int64_t(0x8000000000000000ULL) : (ctx.f0.f64 > double(LLONG_MAX)) ? LLONG_MAX : simde_mm_cvttsd_si64(simde_mm_load_sd(&ctx.f0.f64));
  return ctx.f0.s64;
}
// cod3-pc\generated\default\cod3_pc_recomp.13.cpp:458 sub_820B3F98
__declspec(noinline) inline double frsp(double a) {
  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};
  ctx.fpscr.InitHost();
  ctx.fpscr.disableFlushModeUnconditional();
  ctx.f0.f64 = a;
	// frsp f13,f0
	ctx.f13.f64 = double(float(ctx.f0.f64));
  return ctx.f13.f64;
}
// cod3-pc\generated\default\cod3_pc_recomp.1.cpp:4305 sub_8212C700
__declspec(noinline) inline PPCVRegister dot4(PPCVRegister a, PPCVRegister b) {
  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};
  ctx.fpscr.InitHost();
  ctx.fpscr.enableFlushModeUnconditional();
  ctx.v0 = a; ctx.v7 = b;
	// vmsum4fp128 v0,v0,v7
	simde_mm_store_ps(ctx.v0.f32, simde_mm_dp_ps(simde_mm_load_ps(ctx.v0.f32), simde_mm_load_ps(ctx.v7.f32), 0xFF));
  return ctx.v0;
}
}  // namespace actual
