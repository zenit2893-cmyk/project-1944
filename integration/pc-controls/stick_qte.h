// Keyboard/mouse input for CoD3's stick-driven battle actions, as plain math
// with no SDK dependencies (tests/pc-controls builds it on its own).
//
// The game's receivers (see pc_controls.cpp) read a per-client array of stick
// values in the range +-128: index 0/1 right stick X/Y, 2/3 left stick X/Y.
//
// Stick swirl (InteractInputRcvrStickSwirl, e.g. turning a charge's fuse):
// every frame the stick vector v = (X, -Y) is normalised, and 1 - cos(dA) of
// the angle it turned since last frame is accumulated, signed by the turn
// direction; the sum over 0.1 s, divided by the time, times frame time, 1000
// and m_yaw, is the animation speed. Only one direction counts (the other is
// clamped to zero) and the definition's swirlClockwise flag picks which.
// Because the per-frame term is quadratic in the per-frame angle and is then
// multiplied by the frame time, the same physical rotation is worth a quarter
// as much at 120 Hz as at 60 Hz.
//
// Here the receiver is fed a virtual stick instead: it turns in the required
// direction by whatever the player does - circles with the mouse, the mouse
// wheel, WASD/arrow keys in a circle - plus a real gamepad stick, and every
// per-frame turn is rescaled to the 60 Hz frame the game was tuned for.
#pragma once

#include <algorithm>
#include <cmath>
#include <numbers>

namespace cod3::controls::qte {

constexpr double kPi = std::numbers::pi;
constexpr double kReferenceFrame = 1.0 / 60.0;

inline double WrapAngle(double a) {
  while (a > kPi) a -= 2.0 * kPi;
  while (a < -kPi) a += 2.0 * kPi;
  return a;
}

// Frame-rate compensation factor: how many 60 Hz frames this frame stands for.
inline double FrameScale(double dt) {
  if (!(dt > 0.0)) return 1.0;
  return std::clamp(kReferenceFrame / dt, 0.25, 4.0);
}

// Mouse "crank": a point dragged by the mouse and held on a circle. Moving the
// mouse round in circles of any size turns it; the angle it turns is what the
// player cranked. Straight strokes count as well, by the distance travelled:
// most players reach for left-right shaking before circles, and a crank alone
// barely moves on a straight line.
// The game's speed is quadratic in the turn per frame, so a slow stroke is
// worth little: at this value calm shaking (1200 counts/s, about 3 cm strokes
// three times a second at 800 dpi) matches a gamepad turned once a second.
constexpr double kStrokeCountsPerRadian = 150.0;

struct Crank {
  double radius = 120.0;  // mouse counts
  double x = 120.0;
  double y = 0.0;

  // Returns the unsigned angle turned by this motion.
  double Advance(double dx, double dy) {
    const double before = std::atan2(y, x);
    x += dx;
    y += dy;
    const double length = std::hypot(x, y);
    if (length < 1e-6) {
      x = radius;
      y = 0.0;
      return 0.0;
    }
    x = x / length * radius;
    y = y / length * radius;
    const double cranked = std::abs(WrapAngle(std::atan2(y, x) - before));
    return std::max(cranked, std::hypot(dx, dy) / kStrokeCountsPerRadian);
  }
};

// Direction held on the movement keys as an angle (8 ways), or false.
inline bool KeyDirection(bool up, bool down, bool left, bool right, double& angle) {
  const int x = (right ? 1 : 0) - (left ? 1 : 0);
  const int y = (up ? 1 : 0) - (down ? 1 : 0);
  if (x == 0 && y == 0) return false;
  angle = std::atan2(double(y), double(x));
  return true;
}

struct SwirlInput {
  double dt = kReferenceFrame;      // guest frame time, seconds
  bool clockwise = false;           // definition's swirlClockwise flag
  bool real_valid = false;          // real stick outside the dead zone
  double real_x = 0.0;              // raw array values, +-128
  double real_y = 0.0;
  double player_radians = 0.0;      // keyboard/mouse turning since last frame
};

struct SwirlState {
  double phi = 0.0;                 // virtual stick angle, in v = (X, -Y) terms
  double reservoir = 0.0;           // keyboard/mouse turning not yet fed
  bool previous_real_valid = false;
  double previous_real_angle = 0.0;
};

struct StickValue {
  int x = 0;
  int y = 0;
};

// Spread keyboard/mouse input over frames: a wheel notch arriving in one frame
// would otherwise count far more than the same turn done smoothly, because
// the game's per-frame term is 1 - cos.
constexpr double kReservoirTime = 0.12;  // seconds
constexpr double kMaxStepPerFrame = 1.4;  // radians, per 60 Hz-equivalent frame

inline StickValue StepSwirl(SwirlState& state, const SwirlInput& in, bool rate_fix) {
  // v = (X, -Y): the game's own convention. The result counts when v turns
  // towards +angle, and the clockwise flag negates it.
  const double wanted = in.clockwise ? -1.0 : 1.0;
  const double scale = rate_fix ? FrameScale(in.dt) : 1.0;

  double step = 0.0;
  if (in.real_valid) {
    const double angle = std::atan2(-in.real_y, in.real_x);
    if (state.previous_real_valid) step += WrapAngle(angle - state.previous_real_angle);
    state.previous_real_angle = angle;
    state.previous_real_valid = true;
  } else {
    state.previous_real_valid = false;
  }

  state.reservoir += std::max(0.0, in.player_radians);
  if (state.reservoir > 0.0) {
    const double dt = in.dt > 0.0 ? in.dt : kReferenceFrame;
    const double release = state.reservoir * (1.0 - std::exp(-dt / kReservoirTime));
    state.reservoir -= release;
    if (state.reservoir < 1e-4) state.reservoir = 0.0;
    step += wanted * release;
  }

  step = std::clamp(step * scale, -kMaxStepPerFrame, kMaxStepPerFrame);
  state.phi = WrapAngle(state.phi + step);
  // v = (cos phi, sin phi) -> X = cos, Y = -sin.
  return {int(std::lround(127.0 * std::cos(state.phi))), int(std::lround(-127.0 * std::sin(state.phi)))};
}

// Rowboat (InteractInputRcvrRowboat, update sub_824FC450). With y' = -Y and
// x = X of the stick the definition names (+1092, the right one for boats):
//   phase value v < 0.25: v = clamp((|(x, y')| - 15) * 0.01176, 0, 0.26) once
//     y' >= 15, else 0 - push the stick "up" to catch the water;
//   v >= 0.25: outside radius 50, v = 0.25 + 0.75 * angle / 180, where the
//     angle runs clockwise in (x, y') from straight up through the right
//     side; past 0.98 the stroke counts (flag 8) and v restarts at 0. Inside
//     radius 50 v falls back to 0; x < -70 is a slipped oar (flag 4).
// So a stroke is a clockwise half circle from up to down through the right,
// and the next one starts from up again.
//
// On a mouse: pulling it towards you rows (the stick follows the half circle
// at full deflection), pushing it away - or a short pause - brings the oar
// back through the centre to the top. Circles work too: their lower half
// rows, their upper half recovers. W held rows at a steady pace.
constexpr double kRowStrokeCounts = 350.0;    // mouse counts pulled per full stroke
constexpr double kRowRecoverCounts = 150.0;   // counts pushed to bring the oar back
constexpr double kRowRecoverSeconds = 0.30;   // or this long
constexpr double kRowKeyStrokeSeconds = 0.55;  // one stroke with the key held

struct RowState {
  bool recovering = false;
  double progress = 0.0;  // of the stroke or of the recovery, 0..1
};

struct RowInput {
  double dt = kReferenceFrame;  // seconds since the last update
  double pull = 0.0;            // mouse counts towards the player since then
  double push = 0.0;            // mouse counts away from the player
  bool key_row = false;         // the row key is held
};

// Returns the stick for the receiver in the game's array convention (X, Y).
inline StickValue StepRow(RowState& state, const RowInput& in) {
  const double dt = in.dt > 0.0 ? std::min(in.dt, 0.1) : kReferenceFrame;
  if (!state.recovering) {
    double advance = std::max(0.0, in.pull) / kRowStrokeCounts;
    if (in.key_row) advance = std::max(advance, dt / kRowKeyStrokeSeconds);
    state.progress = std::min(1.0, state.progress + advance);
    const double phi = state.progress * kPi;
    // (x, y') = 127 (sin phi, cos phi): up, then right, then down; Y = -y'.
    const StickValue value{int(std::lround(127.0 * std::sin(phi))), int(std::lround(-127.0 * std::cos(phi)))};
    if (state.progress >= 1.0) {
      state.recovering = true;
      state.progress = 0.0;
    }
    return value;
  }
  state.progress += std::max(0.0, in.push) / kRowRecoverCounts + dt / kRowRecoverSeconds;
  if (state.progress >= 1.0) {
    state.recovering = false;
    state.progress = 0.0;
  }
  return {0, 0};
}

// Stick toggle (InteractInputRcvrStickToggleHoriz/Vert): the receiver flips
// each time the value crosses +-70, so any alternation counts. Keyboard and
// mouse become a full deflection held briefly.
constexpr double kToggleMouseThreshold = 25.0;  // counts gathered within a frame or two
constexpr double kToggleHoldSeconds = 0.09;

struct ToggleState {
  double mouse = 0.0;       // recent mouse motion along the axis, decaying
  double hold_left = 0.0;   // seconds the last mouse flick is still held
  int hold_value = 0;
};

// 'keys' is -1, 0 or +1 from the keyboard; 'mouse' the motion along the axis
// since last frame. Returns the value to feed (+-127), or 0 for "leave the
// real stick alone".
inline int StepToggle(ToggleState& state, int keys, double mouse, double dt) {
  if (!(dt > 0.0)) dt = kReferenceFrame;
  state.mouse = state.mouse * std::exp(-dt / 0.05) + mouse;
  if (std::abs(state.mouse) >= kToggleMouseThreshold) {
    state.hold_value = state.mouse > 0.0 ? 127 : -127;
    state.hold_left = kToggleHoldSeconds;
    state.mouse = 0.0;
  } else {
    state.hold_left = std::max(0.0, state.hold_left - dt);
  }
  if (keys != 0) return keys > 0 ? 127 : -127;
  if (state.hold_left > 0.0) return state.hold_value;
  return 0;
}

}  // namespace cod3::controls::qte
