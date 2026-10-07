function agentC2_fix()
%AGENTC2_FIX  Corrected follow-ups to agentC2_gaps.
%
%   F1  G1 redone with the SUPPORTED programmatic path.  My first attempt used
%       set(S.h.chk_hifi,'Value',1) directly, which never fires onParamChanged,
%       so prepareCommon kept the cached S.P and the run stayed at 1 mm.  The
%       correct call is drm2d_nonlocality_tool('set', f, 'hifi', 1).
%       (My test bug, not a tool defect: the real checkbox has that callback.)
%
%   F2  T40 residual split by the RIGHT regions.  "Outside the planned field"
%       is not where the level-0 term lives: the pinned area extends 3 expansion
%       rings beyond the field, so pins still exist there.  Level 0 (ions that
%       miss the device entirely) only exists OUTSIDE THE PINNED AREA.
%
%   Run:  matlab -batch "agentC2_fix"

here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));
fprintf('\n===== Agent C round 2 : corrected follow-ups =====\n');

%% ------------------------------------------------- F1 ripple, both grids
fprintf('\n--- F1  ripple vs grid, using the supported ''hifi'' API ---\n');
for hv = [0 1]
    f = drm2d_nonlocality_tool('new', 'Visible', 'off');
    drm2d_nonlocality_tool('set', f, 'hifi', hv, 'compareExact', 1);
    drm2d_nonlocality_tool('calcrashi', f);
    drm2d_nonlocality_tool('calc2drm',  f);
    drm2d_nonlocality_tool('applynl',   f);
    S = guidata(f);
    R = S.dose.rashi_Gy;  Rm = max(R(:));
    fprintf(['  hifi=%d  lateral_pixel = %.2g mm | ripple rms: ' ...
             'displayed(diff_pct) %.3f %% | exact-RaShi %.3f %% | local-RaShi %.3f %%\n'], ...
            hv, S.P.lateral_pixel_mm, ...
            rippleOf(S.dose.diff_pct, S.P, R), ...
            rippleOf((S.dose.exact_Gy - R)/Rm*100, S.P, R), ...
            rippleOf((S.dose.local_Gy - R)/Rm*100, S.P, R));
    if hv == 0, Sc = S; end
    close(f);
end

%% ------------------------------------------- F2 T40 split by the right regions
fprintf('\n--- F2  T40 residual split: field / pinned area / beyond the pins ---\n');
S = Sc;  P = S.P;
R = S.dose.rashi_Gy;  Rm = max(R(:));
res = abs(S.dose.exact_Gy - S.dose.after_Gy) / Rm * 100;
xc = 0.5*(S.dose.xEdges_mm(1:end-1) + S.dose.xEdges_mm(2:end));
yc = 0.5*(S.dose.yEdges_mm(1:end-1) + S.dose.yEdges_mm(2:end));

% planned field
fx = abs(xc) <= P.fieldX_mm/2;
fy = (yc >= -P.widthA_mm) & (yc <= P.widthB_mm);
% pinned area = field + the expansion rings
nE   = nExpandRingsLocal(P);
padX = P.fieldX_mm/2 + nE*P.spacing_mm;
padA = P.widthA_mm   + nE*P.spacing_mm;
padB = P.widthB_mm   + nE*P.spacing_mm;
px = abs(xc) <= padX;
py = (yc >= -padA) & (yc <= padB);

mField  = false(size(res));  mField(:,  fx, fy) = true;
mPinned = false(size(res));  mPinned(:, px, py) = true;
mRing   = mPinned & ~mField;          % expansion rings: pins exist, A1 is poor
mBeyond = ~mPinned;                   % no pins at all -> the level-0 term

fprintf('  expansion rings used: %d  (pinned area +-%.1f mm in x)\n', nE, padX);
fprintf('  max residual, planned field        %.3f %%\n', maxOr0(res(mField)));
fprintf('  max residual, expansion rings      %.3f %%   (approximation A1, not level 0)\n', maxOr0(res(mRing)));
fprintf('  max residual, BEYOND the pins      %.3f %%   <- the level-0 edge term\n', maxOr0(res(mBeyond)));
hi = R > 0.5*Rm;
fprintf('  max residual, R > 50%% of max       %.3f %%  (rms %.3f %%)\n', ...
        maxOr0(res(hi)), sqrt(mean(res(hi).^2)));
fprintf('  -> where the overall max sits: %s\n', whereMax(res, mField, mRing, mBeyond));

fprintf('\n===== done =====\n');
end


function s = whereMax(res, mF, mR, mB)
[~, i] = max(res(:));
if mF(i), s = 'inside the planned field';
elseif mR(i), s = 'in the expansion rings';
elseif mB(i), s = 'beyond the pinned area (level-0 region)';
else, s = 'unclassified'; end
end


function v = maxOr0(a)
if isempty(a), v = 0; else, v = max(a(:)); end
end


function ne = nExpandRingsLocal(P)
%NEXPANDRINGSLOCAL  Mirror of the tool's nExpandRings (TRiP2stl size loop).
ne = 0;
if ~strcmpi(P.expand_mode, 'none')
    D = P.spacing_mm;  sig = P.expand_sigma_mm;
    for ii = 2:10
        g = (-ii:ii) * D;
        [XX, YY] = meshgrid(g, g);
        GS = exp(-(XX.^2 + YY.^2) / (2*sig^2)) / (2*pi*sig^2) * D^2;
        if 1 - sum(GS(:)) < P.expand_size_thresh, ne = ii; return; end
    end
    ne = 10;
end
end


function r = rippleOf(D, P, R)
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
