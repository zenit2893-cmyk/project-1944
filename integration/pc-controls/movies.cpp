// Skippable movies.
//
// The movie player checks for "any button" every frame (sub_824D0470), but
// only once the movie has run past a minimum time kept at 0x82A2A258. The
// level briefing that plays while a level loads gets FLT_MAX there
// (sub_824636D0), so after the level had loaded - about 5 s in, a tester log
// shows - the player still sat through the rest of it: 75 s on nightdrop,
// 90 s on mayenne. The legal notice at start-up gets 5000.
//
// With cod3_skip_movies the minimum is 0 for every movie: any button (Space,
// Enter, Esc on the keyboard) ends it. A level briefing can still only end
// once the level has loaded - the player waits for the load in the loop that
// follows it (sub_824EEBA0) - so nothing is cut short that the game needs.

#include <rex/cvar.h>
#include <rex/hook.h>
#include <rex/logging.h>

#include <atomic>
#include <cstdint>
#include <cstring>

REXCVAR_DEFINE_BOOL(cod3_skip_movies, true, "Game",
                    "Any button skips a movie: level briefings once the level has loaded, the rest at once");

REX_EXTERN(__imp__sub_824EEBA0);
REX_EXTERN(__imp__sub_824EF308);
REX_EXTERN(__imp__sub_824D0470);

namespace {

constexpr uint32_t kMovieMinimumTime = 0x82A2A258;

void AllowSkip(uint8_t* base) {
  if (!REXCVAR_GET(cod3_skip_movies)) return;
  std::memset(base + kMovieMinimumTime, 0, 4);  // 0.0f
}

}  // namespace

// SV_SpawnServer's wait for the briefing movie after the level has loaded.
REX_EXTERN(sub_824EEBA0) {
  AllowSkip(base);
  REXLOG_INFO("Game: level loaded; the briefing movie can be skipped with any button");
  __imp__sub_824EEBA0(ctx, base);
}

// Play a movie to the end (front end, legal notice, logos, finale).
REX_EXTERN(sub_824EF308) {
  AllowSkip(base);
  __imp__sub_824EF308(ctx, base);
}

// The player's per-frame skip check: 1 when a button ended the movie.
REX_EXTERN(sub_824D0470) {
  __imp__sub_824D0470(ctx, base);
  if (ctx.r3.u32 == 1) REXLOG_INFO("Game: movie skipped");
}
