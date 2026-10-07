function agentC2_gaps()
%AGENTC2_GAPS  Agent C round-2 verification of the PLAN2 implementation.
%
%   Covers what Agent B's self-written selftest does NOT:
%     G1  ripple investigation (Priority 3) - where does the pin ripple live?
%     G2  T40 measurement, and the in-field / outside-field (level-0) split
%     G3  mixed-geometry guard: btn_apply as well as btn_diff, GUI AND programmatic
%     G4  stale exact_Gy across a geometry change and across Reset
%     G5  fig3_maps panel count with / without Compare-exact (the T48/T49 gap)
%     G6  T54 per-zone vs global margin (Agent B asserted only ">")
%     G7  info-box VALUES vs direct computation (PLAN2 T51/T53 ask for a match)
%
%   Run:  matlab -batch "cd matlab/tests; agentC2_gaps"

here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));          % so drm2d_nonlocality_tool is on the path
fprintf('\n===== Agent C round 2 : gap tests =====\n');

%% ---------------------------------------------------------------- G1 ripple
fprintf('\n--- G1  where does the pin ripple live? ---\n');
Sc = [];
for mode = {'coarse', 'hifi'}
    f = drm2d_nonlocality_tool('new', 'Visible', 'off');
    S = guidata(f);
    set(S.h.chk_exact, 'Value', 1);                 % need the exact 2DRM
    if strcmp(mode{1}, 'hifi'), set(S.h.chk_hifi, 'Value', 1); end
    drm2d_nonlocality_tool('calcrashi', f);
    drm2d_nonlocality_tool('calc2drm',  f);
    drm2d_nonlocality_tool('applynl',   f);
    S = guidata(f);
    R = S.dose.rashi_Gy;  Rm = max(R(:));
    rDisp  = rippleOf(S.dose.diff_pct, S.P, R);                     % what the info box reports
    rExact = rippleOf((S.dose.exact_Gy - R)/Rm*100, S.P, R);        % the project's ~1.35 %
    rLocal = rippleOf((S.dose.local_Gy - R)/Rm*100, S.P, R);        % should be ~0 (same fluence)
    fprintf(['  %-7s pixel %.2g mm | ripple rms: displayed(diff_pct) %.3f %% | ' ...
             'exact-RaShi %.3f %% | local-RaShi %.3f %%\n'], ...
            mode{1}, S.P.lateral_pixel_mm, rDisp, rExact, rLocal);
    if strcmp(mode{1}, 'coarse'), Sc = S; end
    close(f);
end

%% ------------------------------------------------------------------ G2 T40
fprintf('\n--- G2  T40 residual, and the in-field / outside-field split ---\n');
S = Sc;
R = S.dose.rashi_Gy;  Rm = max(R(:));
res = abs(S.dose.exact_Gy - S.dose.after_Gy) / Rm * 100;
yc  = 0.5*(S.dose.yEdges_mm(1:end-1) + S.dose.yEdges_mm(2:end));
xc  = 0.5*(S.dose.xEdges_mm(1:end-1) + S.dose.xEdges_mm(2:end));
inX = abs(xc) <= S.P.fieldX_mm/2;
inY = (yc >= -S.P.widthA_mm) & (yc <= S.P.widthB_mm);     % the planned field in y
inField = false(size(res));
inField(:, inX, inY) = true;
hi = R > 0.5*Rm;
fprintf('  max residual, whole grid       %.3f %%\n', max(res(:)));
fprintf('  max residual, inside field     %.3f %%\n', max(res(inField)));
fprintf('  max residual, outside field    %.3f %%   <- the level-0 edge term\n', max(res(~inField)));
fprintf('  max residual, R > 50%% of max   %.3f %%   (rms %.3f %%)\n', ...
        max(res(hi)), sqrt(mean(res(hi).^2)));

%% ------------------------------------------- G3 mixed-geometry guard, both paths
fprintf('\n--- G3  mixed-geometry guard ---\n');
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('set', f, 'heightB_mm', 20);
drm2d_nonlocality_tool('calc2drm', f);
S = guidata(f);
fprintf('  btn_diff  Enable = %-3s (expect off)\n', get(S.h.btn_diff,  'Enable'));
fprintf('  btn_apply Enable = %-3s (expect off)\n', get(S.h.btn_apply, 'Enable'));
drm2d_nonlocality_tool('seediff', f);
drm2d_nonlocality_tool('applynl', f);
S = guidata(f);
fprintf('  programmatic seediff+applynl refused: diff_pct empty=%d after_Gy empty=%d (expect 1 1)\n', ...
        isempty(S.dose.diff_pct), isempty(S.dose.after_Gy));
close(f);

f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('set', f, 'heightB_mm', 20);
drm2d_nonlocality_tool('applynl', f);        % auto-compute path, NEW geometry
S = guidata(f);
fprintf('  auto-compute path refused: after_Gy empty=%d (expect 1)\n', isempty(S.dose.after_Gy));
close(f);

%% --------------------------------------------------- G4 stale exact_Gy
fprintf('\n--- G4  can a stale exact_Gy survive a geometry change / Reset? ---\n');
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
S = guidata(f);  set(S.h.chk_exact, 'Value', 1);
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('calc2drm',  f);
e1 = guidata(f).dose.exact_Gy;
S = guidata(f);  set(S.h.chk_exact, 'Value', 0);      % untick
drm2d_nonlocality_tool('set', f, 'heightB_mm', 20);   % change geometry
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('calc2drm',  f);
drm2d_nonlocality_tool('applynl',   f);
S = guidata(f);
stale = ~isempty(S.dose.exact_Gy) && isequal(S.dose.exact_Gy, e1);
fprintf('  exact_Gy is still the OLD geometry array: %d   (1 = stale data retained)\n', stale);
txt = get(S.h.txt_info, 'String');  if ~iscell(txt), txt = cellstr(txt); end
j = strjoin(txt(:)', ' | ');
fprintf('  info box "model vs exact" = %.3f %%   (fed by the stale array if above is 1)\n', ...
        local_num(j, 'model vs exact\s+([\d.]+)'));
drm2d_nonlocality_tool('reset', f);
fprintf('  exact_Gy survives Reset: %d   (PLAN2 s1 lists exact_Gy in the clear-set)\n', ...
        ~isempty(guidata(f).dose.exact_Gy));
close(f);

%% ------------------------------------------- G5 fig3_maps panel count
fprintf('\n--- G5  fig3_maps panel count ---\n');
for ex = [0 1]
    f = drm2d_nonlocality_tool('new', 'Visible', 'off');
    S = guidata(f);  set(S.h.chk_exact, 'Value', ex);
    drm2d_nonlocality_tool('calcrashi', f);
    drm2d_nonlocality_tool('calc2drm',  f);
    drm2d_nonlocality_tool('applynl',   f);
    H = drm2d_nonlocality_tool('result', f);
    n = NaN;
    for i = 1:numel(H)
        if contains(lower(get(H(i), 'Name')), 'maps y-z')
            n = numel(findobj(H(i), 'Type', 'axes'));
        end
    end
    fprintf('  chk_exact=%d -> fig3_maps axes = %d  (expect 2 without, 4 with)\n', ex, n);
    close(H);  close(f);
end

%% ------------------------------------------------ G6 T54 margin
fprintf('\n--- G6  per-zone vs global margin at Region B = 10 mm ---\n');
f = drm2d_nonlocality_tool('new', 'Visible', 'off', 'heightB_mm', 10);
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('calc2drm',  f);
drm2d_nonlocality_tool('applynl',   f);
S = guidata(f);
gl = max(abs(S.dose.diff_pct(:)));
pz = perZonePeakIndependent(S);
fprintf('  global %.3f %%   per-zone %.3f %%   ratio %.3f   (PLAN2 T54 suggests > 2)\n', ...
        gl, pz, pz/gl);
close(f);

%% ------------------------------------------------ G7 info-box values
fprintf('\n--- G7  info-box values vs direct computation ---\n');
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('calc2drm',  f);
drm2d_nonlocality_tool('seediff',   f);
S = guidata(f);
txt = get(S.h.txt_info, 'String');  if ~iscell(txt), txt = cellstr(txt); end
j = strjoin(txt(:)', ' | ');
maxR = max(S.dose.rashi_Gy(:));  maxL = max(S.dose.local_Gy(:));
sR = local_num(j, 'max RaShi\s+([\d.]+)');
sL = local_num(j, 'max 2DRM \(local\)\s+([\d.]+)');
D  = S.dose.diff_pct;  [~, i] = max(abs(D(:)));
sPk = local_num(j, 'peak \|dD\|\s+([\d.]+)');
fprintf('  max RaShi  shown %.5f  actual %.5f  -> %s\n', sR, maxR, tf(abs(sR-maxR) < 1e-5));
fprintf('  max 2DRM   shown %.5f  actual %.5f  -> %s\n', sL, maxL, tf(abs(sL-maxL) < 1e-5));
fprintf('  peak |dD|  shown %.3f   actual %.3f   -> %s\n', sPk, abs(D(i)), tf(abs(sPk-abs(D(i))) < 5e-3));
close(f);

fprintf('\n===== done =====\n');
end


function r = rippleOf(D, P, R)
%RIPPLEOF  rms of D about its pin-cell block mean, over the high-dose voxels [%].
r = NaN;
if isempty(D), return; end
f = round(P.spacing_mm / P.voxel_mm);
if f < 2, return; end
[~, nx, ny] = size(D);
nx2 = nx - mod(nx, f);  ny2 = ny - mod(ny, f);
D  = D(:, 1:nx2, 1:ny2);
Rc = R(:, 1:nx2, 1:ny2);
c  = repelem(blockMeanLocal(D, f), 1, f, f);
res = D - c;
m = Rc > 0.5*max(R(:));
if ~any(m(:)), return; end
r = sqrt(mean(res(m).^2));
end


function out = blockMeanLocal(d, f)
%BLOCKMEANLOCAL  Same two-step reduction as the tool's blockMean3.
[nz, nx, ny] = size(d);
nx2 = nx - mod(nx, f);  ny2 = ny - mod(ny, f);
d = d(:, 1:nx2, 1:ny2);
d = reshape(d, nz, f, nx2/f, ny2);
d = squeeze(mean(d, 2));
if nz == 1, d = reshape(d, 1, nx2/f, ny2); end
d = reshape(d, nz, nx2/f, f, ny2/f);
out = squeeze(mean(d, 3));
if nz == 1, out = reshape(out, 1, nx2/f, ny2/f); end
end


function pct = perZonePeakIndependent(S)
%PERZONEPEAKINDEPENDENT  Peak |after - rashi| relative to each zone's own
%   plateau dose, computed here rather than via the tool, so G6 is independent.
R = S.dose.rashi_Gy;  A = S.dose.after_Gy;  P = S.P;
xc = 0.5*(S.dose.xEdges_mm(1:end-1) + S.dose.xEdges_mm(2:end));
yc = 0.5*(S.dose.yEdges_mm(1:end-1) + S.dose.yEdges_mm(2:end));
mx = abs(xc) <= P.fieldX_mm/2;
inA = yc < 0 & abs(yc) <= P.widthA_mm;
inB = yc > 0 & abs(yc) <= P.widthB_mm;
sa = R(:, mx, inA);  refA = max(sa(:));
sb = R(:, mx, inB);  refB = max(sb(:));
ref = zeros(size(yc));  ref(yc < 0) = refA;  ref(yc >= 0) = refB;
ref(~isfinite(ref) | ref <= 0) = NaN;
rel = abs(A - R) ./ reshape(ref, 1, 1, []);
pct = max(rel(isfinite(rel))) * 100;
end


function v = local_num(j, pat)
t = regexp(j, pat, 'tokens', 'once');
if isempty(t), v = NaN; else, v = str2double(t{1}); end
end


function s = tf(b)
if b, s = 'MATCH'; else, s = 'MISMATCH'; end
end
