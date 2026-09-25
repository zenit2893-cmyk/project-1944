// Checks integration/pc-controls/stick_qte.h against a model of CoD3's own
// stick-swirl receiver, transcribed from the recompiled guest code:
//   sub_8250C6D8  angle step between this frame's and last frame's stick
//   sub_82508238  InteractInputRcvrStickSwirl update (0.1 s windows)
//   sub_82509C78  mean of the last five window rates
// Output of the receiver is the fuse-turn animation speed.
//
// Build: clang-cl /std:c++20 /EHsc /O2 stick_qte_test.cpp (see run.ps1).
#include "../../integration/pc-controls/stick_qte.h"

#include <cmath>
#include <cstdio>
#include <functional>

using namespace cod3::controls::qte;

namespace {

struct GameSwirl {
  bool clockwise = false;
  double m_yaw = 0.7;  // the console default the receiver scales by
  double prev[3] = {0, 0, 0};
  double window_time = 0, window_sum = 0, rate = 0;
  double history[5] = {0, 0, 0, 0, 0};
  int counter = 0;

  double Update(int stick_x, int stick_y, double dt) {
    // sub_8250C6D8
    double dot = -2.0;
    int direction = 0;
    double cx = stick_x, cy = -double(stick_y);
    const double length = std::sqrt(cx * cx + cy * cy);
    if (length != 0.0) {
      cx /= length;
      cy /= length;
    }
    if (!(prev[0] == 0.0 && prev[1] == 0.0)) {
      const double cross = cy * prev[0] - prev[1] * cx;
      dot = prev[0] * cx + prev[1] * cy;
      if (cross > 0) direction = 1;
      else if (cross < 0) direction = -1;
    }
    prev[0] = cx;
    prev[1] = cy;
    // sub_82508238
    const double contribution = (1.0 - dot) * direction;
    if (window_time > 0.1) {
      rate = window_sum / window_time;
      if (counter >= 5) counter = 0;  // sub_82509C78
      history[counter] = rate;
      rate = 0.2 * (history[0] + history[1] + history[2] + history[3] + history[4]);
      window_time = 0;
      window_sum = 0;
      ++counter;
    } else {
      window_time += dt;
      window_sum += contribution;
    }
    double output = dt * 1000.0 * m_yaw * rate;
    if (clockwise) output = -output;
    return output > 0 ? output : 0;
  }
};

// Runs 'seconds' of guest frames at 'hz' and returns the mean output over the
// last second. 'feed' returns the stick for the frame at time t.
double Run(double hz, double seconds, bool clockwise,
           const std::function<StickValue(double t, double dt)>& feed) {
  GameSwirl game;
  game.clockwise = clockwise;
  const double dt = 1.0 / hz;
  double sum = 0;
  int count = 0;
  for (double t = 0; t < seconds; t += dt) {
    const StickValue v = feed(t, dt);
    const double out = game.Update(v.x, v.y, dt);
    if (t > seconds - 1.0) {
      sum += out;
      ++count;
    }
  }
  return count ? sum / count : 0;
}

// A real stick turning at 'revs' per second (positive = increasing angle of
// (X, Y), i.e. what the player sees as counter-clockwise with Y up).
StickValue RealStick(double t, double revs) {
  const double a = 2 * kPi * revs * t;
  return {int(std::lround(127 * std::cos(a))), int(std::lround(127 * std::sin(a)))};
}

int failures = 0;
void Expect(bool ok, const char* what) {
  std::printf("  [%s] %s\n", ok ? " ok " : "FAIL", what);
  if (!ok) ++failures;
}

}  // namespace

int main() {
  // 1. The game on its own: the frame-rate dependence.
  std::printf("Game only, gamepad stick, 1 rev/s in the counting direction:\n");
  // With clockwise=false the result counts when v=(X,-Y) turns positive, i.e.
  // when (X,Y) turns negative.
  const double raw60 = Run(60, 4, false, [](double t, double) { return RealStick(t, -1.0); });
  const double raw120 = Run(120, 4, false, [](double t, double) { return RealStick(t, -1.0); });
  const double wrong60 = Run(60, 4, false, [](double t, double) { return RealStick(t, 1.0); });
  std::printf("  60 Hz %.2f   120 Hz %.2f   wrong way %.2f\n", raw60, raw120, wrong60);
  Expect(raw60 > 1.0, "60 Hz produces a speed");
  Expect(raw120 < raw60 * 0.35, "120 Hz produces about a quarter (the bug being fixed)");
  Expect(wrong60 == 0.0, "the wrong direction produces nothing");

  // 2. The same gamepad through StepSwirl with the frame-rate fix.
  std::printf("Gamepad through the assist, 1 rev/s:\n");
  auto through = [](double hz, bool clockwise, double revs) {
    SwirlState state;
    return Run(hz, 4, clockwise, [&](double t, double dt) {
      const StickValue real = RealStick(t, revs);
      SwirlInput in;
      in.dt = dt;
      in.clockwise = clockwise;
      in.real_valid = true;
      in.real_x = real.x;
      in.real_y = real.y;
      return StepSwirl(state, in, true);
    });
  };
  const double fix60 = through(60, false, -1.0), fix120 = through(120, false, -1.0);
  const double fix120wrong = through(120, false, 1.0);
  std::printf("  60 Hz %.2f   120 Hz %.2f   wrong way at 120 Hz %.2f\n", fix60, fix120, fix120wrong);
  Expect(std::abs(fix60 - raw60) < raw60 * 0.05, "60 Hz unchanged by the assist");
  Expect(std::abs(fix120 - fix60) < fix60 * 0.10, "120 Hz now matches 60 Hz");
  Expect(fix120wrong == 0.0, "the gamepad still has to turn the right way");

  // 3. Keyboard and mouse at 120 Hz, both flag values, both directions.
  std::printf("Keyboard/mouse at 120 Hz:\n");
  for (int clockwise = 0; clockwise < 2; ++clockwise) {
    for (int sense = -1; sense <= 1; sense += 2) {
      // Mouse: a 300-count circle at 1.5 rev/s, events at 1000 Hz.
      SwirlState state;
      Crank crank;
      double mouse_t = 0, mx = 300, my = 0;
      const double mouse = Run(120, 4, clockwise, [&](double t, double dt) {
        double turned = 0;
        while (mouse_t < t + dt) {
          mouse_t += 0.001;
          const double a = sense * 2 * kPi * 1.5 * mouse_t;
          const double nx = 300 * std::cos(a), ny = 300 * std::sin(a);
          turned += crank.Advance(nx - mx, ny - my);
          mx = nx;
          my = ny;
        }
        SwirlInput in;
        in.dt = dt;
        in.clockwise = clockwise;
        in.player_radians = turned;
        return StepSwirl(state, in, true);
      });
      // Wheel: 12 notches per second, 45 degrees each.
      SwirlState wheel_state;
      double next_notch = 0;
      const double wheel = Run(120, 4, clockwise, [&](double t, double dt) {
        double turned = 0;
        while (next_notch < t + dt) {
          next_notch += 1.0 / 12.0;
          turned += kPi / 4;
        }
        SwirlInput in;
        in.dt = dt;
        in.clockwise = clockwise;
        in.player_radians = turned;
        return StepSwirl(wheel_state, in, true);
      });
      // Keys: W, D, S, A round and round, 6 key changes per second.
      SwirlState key_state;
      double key_angle = 0;
      bool key_valid = false;
      const double keys = Run(120, 4, clockwise, [&](double t, double dt) {
        const int step = int(t * 6) % 4;
        const int index = sense > 0 ? step : (4 - step) % 4;
        double angle = 0;
        KeyDirection(index == 0, index == 2, index == 3, index == 1, angle);
        double turned = key_valid ? std::abs(WrapAngle(angle - key_angle)) : 0;
        key_angle = angle;
        key_valid = true;
        SwirlInput in;
        in.dt = dt;
        in.clockwise = clockwise;
        in.player_radians = turned;
        return StepSwirl(key_state, in, true);
      });
      // Mouse shaken left and right: 400-count strokes, 3 a second (1200
      // counts/s), fed once per guest frame as the game thread sees it.
      SwirlState shake_state;
      Crank shake_crank;
      double shake_x = 0;
      const double shake = Run(120, 4, clockwise, [&](double t, double dt) {
        const double phase = std::fmod((t + dt) * 3.0, 2.0);
        const double x = 400.0 * (phase < 1.0 ? phase : 2.0 - phase);
        const double turned = shake_crank.Advance(x - shake_x, 0.0);
        shake_x = x;
        SwirlInput in;
        in.dt = dt;
        in.clockwise = clockwise;
        in.player_radians = turned;
        return StepSwirl(shake_state, in, true);
      });
      std::printf("  swirlClockwise=%d, player turns %s: mouse %.2f  shake %.2f  wheel %.2f  keys %.2f\n", clockwise,
                  sense > 0 ? "one way  " : "other way", mouse, shake, wheel, keys);
      Expect(mouse > raw60, "mouse circles at 1.5 rev/s beat a gamepad at 1 rev/s");
      Expect(shake > raw60 * 0.8, "shaking the mouse left and right turns it about as fast as a gamepad");
      Expect(wheel > 1.0, "the wheel turns it");
      Expect(keys > 1.0, "WASD in a circle turns it");
    }
  }

  // 4. Nothing pressed: nothing happens.
  SwirlState idle;
  const double none = Run(120, 3, false, [&](double, double dt) {
    SwirlInput in;
    in.dt = dt;
    return StepSwirl(idle, in, true);
  });
  Expect(none == 0.0, "no input, no progress");

  // 5. Rowboat: the receiver sub_824FC450 transcribed (constants from the
  // image: 15, 0.01176, 0.26, 0.25, 50^2, -70, 30, 0.00556, 0.75, 0.98) and
  // the angle helper sub_824FC248 (atan2 in degrees, (90 - angle) mod 360).
  struct GameRow {
    double v = 0;
    int strokes = 0, slips = 0;
    void Update(int stick_x, int stick_y) {
      const double x = stick_x, yp = -double(stick_y);
      if (v < 0.25) {
        v = yp < 15.0 ? 0.0 : std::clamp((std::hypot(x, yp) - 15.0) * 0.01176, 0.0, 0.26);
        return;
      }
      if (x * x + yp * yp <= 2500.0) {
        v = 0;
        return;
      }
      if (x < -70.0) {
        ++slips;
        return;
      }
      double theta = std::atan2(yp, x) * 180.0 / kPi;
      if (theta < 0) theta += 360.0;
      double angle = 360.0 - theta + 90.0;
      if (angle >= 360.0) angle -= 360.0;
      if (angle > 225.0) angle = 0.0;
      v = std::min(angle * 0.00556 * 0.75 + 0.25, 1.0);
      if (v > 0.98) {
        ++strokes;
        v = 0;
      }
    }
  };
  std::printf("Rowboat at 120 Hz:\n");
  auto row = [](double seconds, const std::function<RowInput(double t, double dt)>& feed) {
    GameRow game;
    RowState state;
    const double dt = 1.0 / 120.0;
    for (double t = 0; t < seconds; t += dt) {
      RowInput in = feed(t, dt);
      in.dt = dt;
      const StickValue s = StepRow(state, in);
      game.Update(s.x, s.y);
    }
    return game;
  };
  // Mouse pulled towards the player 800 counts/s for 0.5 s, pushed back
  // 800 counts/s for 0.5 s: one stroke a second.
  const GameRow pulls = row(10, [](double t, double dt) {
    RowInput in;
    const bool pulling = std::fmod(t, 1.0) < 0.5;
    (pulling ? in.pull : in.push) = 800.0 * dt;
    return in;
  });
  // Mouse circles, 1 a second, 250-count radius (1570 counts round).
  double cy = 0;
  const GameRow circles = row(10, [&](double t, double dt) {
    RowInput in;
    const double y = 250.0 * std::sin(2 * kPi * (t + dt)) - 250.0 * std::sin(2 * kPi * t);
    (y > 0 ? in.pull : in.push) = std::abs(y);
    cy += y;
    return in;
  });
  const GameRow keys = row(10, [](double, double) {
    RowInput in;
    in.key_row = true;
    return in;
  });
  const GameRow row_idle = row(5, [](double, double) { return RowInput{}; });
  std::printf("  pull/push 1/s: %d strokes, %d slips; circles 1/s: %d strokes, %d slips; W held: %d strokes, %d slips\n",
              pulls.strokes, pulls.slips, circles.strokes, circles.slips, keys.strokes, keys.slips);
  Expect(pulls.strokes >= 9 && pulls.slips == 0, "pulling and pushing the mouse rows once per pull, no slips");
  Expect(circles.strokes >= 9 && circles.slips == 0, "mouse circles row once per circle, no slips");
  Expect(keys.strokes >= 10 && keys.slips == 0, "the row key rows by itself");
  Expect(row_idle.strokes == 0, "no input, no rowing");

  // 6. Toggle: alternating A/D and mouse flicks give alternating extremes.
  ToggleState toggle;
  const int a = StepToggle(toggle, -1, 0, 1.0 / 120), d = StepToggle(toggle, 1, 0, 1.0 / 120);
  ToggleState flick;
  const int right = StepToggle(flick, 0, 40, 1.0 / 120);
  const int held = StepToggle(flick, 0, 0, 1.0 / 120);
  const int left = StepToggle(flick, 0, -40, 1.0 / 120);
  int after = 0;
  for (int i = 0; i < 30; ++i) after = StepToggle(flick, 0, 0, 1.0 / 120);
  Expect(a == -127 && d == 127, "toggle keys give full deflection");
  Expect(right == 127 && held == 127 && left == -127, "mouse flicks give full deflection and hold briefly");
  Expect(after == 0, "a flick is released afterwards");

  std::printf(failures ? "\n%d check(s) FAILED\n" : "\nall checks passed\n", failures);
  return failures ? 1 : 0;
}
