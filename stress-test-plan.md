# Plan

in order to stress test need to:
- [x] reliably have mouse control capture on a window when menu is closed/open and switching between windows
- [x] model arms & swinging, eyes & looking
- [x] chat system
- [x] main menu with connect options
- [x] safe disconnect option
- [x] player state (crouching)
- [x] repeat last actions mode for having many windows open
- [x] option for player count to test server fullness
- [x] graceful exit for client and server

nice to haves:
- [ ] client packet buffering
- [ ] lag compensation testing option
- [x] fix crouching logic?
- [ ] set simulated ping on client via debug menu
- [x] github builds bundles

server authoritative changes before test:
- [ ] server runs physics
- [ ] client does pose estimates for self
- [ ] client does pose estimates for others
- [ ] client state buffering and interpolation for other players

# server input refactoring

- gravity applies to every charater, server/client, authority or not
- movement:
    - on server: apply movement from input packet
    - on client:
        - authority (self): apply movement from input and reconcile with server
        - not authority (others): buffer, lerp, and apply movement from servers