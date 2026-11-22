# Controller profiles are data, with optional keys that default to the LC6000

2026-11-16. Each controller is described by a profile file, not by code (#43). Behavior that was still LC6000-specific moves into optional profile keys whose default is the LC6000's value (#48, #192), so the bundled LC6000 profile and every saved profile keep loading unchanged, and a new controller needs only a new file. The import check refuses a profile with plain-word problems rather than a decoder dump. A profile can also be drafted from an owner's capture (#189).
