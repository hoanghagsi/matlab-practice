function agentC3_probe()
%AGENTC3_PROBE  Agent C retest after Agent B's fix round 1 (defects D1, D2).
%   Sections:
%     P1  the ORIGINAL D1 reproducer (agentC2_gaps.m G4) re-run verbatim
%     P2  a SUSPECTED SURVIVING STALE PATH: rashi_Gy stale while exact/local current
%     P3  Reset keeps a VALID exact dose usable (Agent B's departure)
%   Run: matlab -batch "addpath('..'); agentC3_probe"

fprintf('\n================ AGENT C3 PROBE ================\n');

%% ---------------------------------------------------------------- P1
% Original D1 reproducer.  Before the fix the info box printed 52.000 %%.
fprintf('\n--- P1: original D1 reproducer (G4 verbatim) ---\n');
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'compareExact', 1);
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('calc2drm',  f);
S = guidata(f);
exactOld = S.dose.exact_Gy;
fprintf('P1  exact dose computed at heightB=40 : %d\n', ~isempty(exactOld));

drm2d_nonlocality_tool('set', f, 'compareExact', 0);     % untick
drm2d_nonlocality_tool('set', f, 'heightB_mm', 20);      % change geometry
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('calc2drm',  f);
drm2d_nonlocality_tool('applynl',   f);
S = guidata(f);

stillOld = isequal(S.dose.exact_Gy, exactOld);
fprintf('P1  exact_Gy is still the OLD array    : %d\n', stillOld);
fprintf('P1  exactIsCurrent now                 : %d  (want 0)\n', ...
        sameGeomProbe(S));
info = get(S.h.txt_info, 'String');
line = findLine(info, 'model vs exact');
fprintf('P1  info box "model vs exact"          : %s\n', strtrim(line));
nf = numel(drm2d_nonlocality_tool('result', f));
fprintf('P1  figures from Result                : %d\n', nf);
closeFigs();

%% ---------------------------------------------------------------- P2
% SUSPECTED HOLE.  exactIsCurrent compares PusedExact <-> PusedLocal only.
% pinRippleRms forms (exact - rashi) but never checks PusedRashi, and unlike
% the other two consumers it does NOT require after_Gy, so the mixed-geometry
% guard is not reached transitively.
fprintf('\n--- P2: stale rashi_Gy vs current exact/local ---\n');
g = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', g, 'compareExact', 1);
drm2d_nonlocality_tool('calcrashi', g);                  % geom1: heightB = 40
S = guidata(g);
rashiOld = S.dose.rashi_Gy;
fprintf('P2  rashi computed at heightB=40       : %d\n', ~isempty(rashiOld));

drm2d_nonlocality_tool('set', g, 'heightB_mm', 20);      % geom2, rashi NOT recomputed
drm2d_nonlocality_tool('calc2drm',  g);                  % local+exact at geom2
S = guidata(g);

fprintf('P2  rashi_Gy still the OLD geom1 array : %d\n', isequal(S.dose.rashi_Gy, rashiOld));
fprintf('P2  PusedRashi == PusedLocal           : %d  (want 0 = mixed)\n', ...
        isequaln(S.dose.PusedRashi, S.dose.PusedLocal));
fprintf('P2  exactIsCurrent (PusedExact=Local)  : %d\n', sameGeomProbe(S));
info = get(S.h.txt_info, 'String');
rl = findLine(info, 'pin ripple rms');
fprintf('P2  info box "pin ripple rms"          : %s\n', strtrim(rl));
if ~contains(rl, '-  (tick')
    fprintf('P2  *** A NUMBER IS SHOWN FROM MIXED GEOMETRY ***\n');
end
% what the honest value would be: recompute rashi at geom2
drm2d_nonlocality_tool('calcrashi', g);
S = guidata(g);
info2 = get(S.h.txt_info, 'String');
fprintf('P2  honest ripple (rashi recomputed)   : %s\n', ...
        strtrim(findLine(info2, 'pin ripple rms')));
closeFigs();

%% ---------------------------------------------------------------- P3
% Agent B's departure: a VALID exact dose must survive Reset and stay usable.
fprintf('\n--- P3: valid exact dose survives Reset and stays usable ---\n');
e = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', e, 'compareExact', 1);
drm2d_nonlocality_tool('calcrashi', e);
drm2d_nonlocality_tool('calc2drm',  e);
drm2d_nonlocality_tool('applynl',   e);
S = guidata(e);
beforeReset = strtrim(findLine(get(S.h.txt_info,'String'), 'pin ripple rms'));
drm2d_nonlocality_tool('reset', e);
S = guidata(e);
afterReset = strtrim(findLine(get(S.h.txt_info,'String'), 'pin ripple rms'));
fprintf('P3  ripple before Reset                : %s\n', beforeReset);
fprintf('P3  ripple after  Reset                : %s\n', afterReset);
fprintf('P3  exact_Gy survives Reset            : %d\n', ~isempty(S.dose.exact_Gy));
fprintf('P3  still current after Reset          : %d  (want 1)\n', sameGeomProbe(S));
closeFigs();

fprintf('\n================ PROBE DONE ================\n');
end

% ------------------------------------------------------------------ helpers
function tf = sameGeomProbe(S)
%SAMEGEOMPROBE  Re-implement exactIsCurrent from OUTSIDE the file under test,
%   so the probe does not depend on the function it is checking.
tf = ~isempty(S.dose.exact_Gy) && ~isempty(S.dose.PusedExact) && ...
     ~isempty(S.dose.PusedLocal) && isequaln(S.dose.PusedExact, S.dose.PusedLocal);
end

function s = findLine(info, key)
if ischar(info), info = cellstr(info); end
s = '(not found)';
for i = 1:numel(info)
    if contains(info{i}, key), s = info{i}; return; end
end
end

function closeFigs()
close(findobj(0, 'Type', 'figure'));
end
