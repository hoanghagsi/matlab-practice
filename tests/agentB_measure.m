function agentB_measure()
%AGENTB_MEASURE  Measure PLAN2 T40 and the per-button runtimes at the DEFAULT
%   geometry (Region A 15 mm / 60 mm WEPL, Region B 15 mm / 40 mm WEPL,
%   240 MeV/u, FWHM 6 mm, coarse 1 mm pixels), with "Compare exact 2DRM" on.
%
%   T40 = max | (local + dD_NL) - exact | / max(rashi) * 100   [%]
%   The residual is the pin ripple plus the level-0 edge term; both are
%   reported separately so Agent C can set the bound knowing the split.
addpath(fileparts(fileparts(mfilename('fullpath'))));
fprintf('--- Agent B measurements (default geometry, coarse grid) ---\n');

f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'compareExact', 1);

t = tic;  drm2d_nonlocality_tool('calcrashi', f);  tR = toc(t);
t = tic;  drm2d_nonlocality_tool('calc2drm',  f);  tL = toc(t);   % includes exact
t = tic;  drm2d_nonlocality_tool('seediff',   f);  tD = toc(t);
t = tic;  drm2d_nonlocality_tool('applynl',   f);  tA = toc(t);
t = tic;  H = drm2d_nonlocality_tool('result', f); tF = toc(t);  close(H);
t = tic;  drm2d_nonlocality_tool('reset',     f);  tZ = toc(t);

fprintf('\nRUNTIMES [s]\n');
fprintf('  1 Calculate (RaShi)        %6.1f\n', tR);
fprintf('  2 Calculate (2DRM local)   %6.1f   (includes the exact 2DRM)\n', tL);
fprintf('  3 See difference           %6.1f\n', tD);
fprintf('  4 Apply non-locality       %6.1f\n', tA);
fprintf('  5 Result (6 figures)       %6.1f\n', tF);
fprintf('  6 Reset                    %6.1f\n', tZ);

drm2d_nonlocality_tool('applynl', f);          % restore the after state
S = guidata(f);
R = S.dose.rashi_Gy;  L = S.dose.local_Gy;
A = S.dose.after_Gy;  E = S.dose.exact_Gy;
Rmax = max(R(:));

if isempty(E)
    fprintf('\nT40: exact 2DRM missing - cannot measure.\n');
    close(f); return;
end

res = (A - E) / Rmax * 100;                    % model minus truth [%]
fprintf('\nT40  max |(local + dD) - exact| / max(RaShi)\n');
fprintf('  whole grid                 %6.3f %%\n', max(abs(res(:))));

% inside the planned field only -- excludes the level-0 region, where ions
% miss the device entirely (F_R(0)=0 but F_M(0)~=0 outside the pinned area)
xe = S.dose.xEdges_mm;  ye = S.dose.yEdges_mm;
xc = 0.5*(xe(1:end-1) + xe(2:end));
yc = 0.5*(ye(1:end-1) + ye(2:end));
P  = S.dose.PusedLocal;
mx = abs(xc) <= P.fieldX_mm/2;
my = yc >= -P.widthA_mm & yc <= P.widthB_mm;
inF = res(:, mx, my);
fprintf('  inside the planned field   %6.3f %%\n', max(abs(inF(:))));
fprintf('  outside it (level-0 term)  %6.3f %%\n', max(abs(res(:))) - max(abs(inF(:))));

% high-dose region only (where a clinical comparison would be made)
m = R > 0.5 * Rmax;
fprintf('  over R > 50 %% of max       %6.3f %%  (rms %.3f %%)\n', ...
        max(abs(res(m))), sqrt(mean(res(m).^2)));

rr = pinRippleRms_probe(S, P);
fprintf('  pin ripple rms of the diff %6.3f %%\n', rr);

fprintf('\n  (material term alone, local-rashi: %+.3f .. %+.3f %%)\n', ...
        min((L(:)-R(:)))/Rmax*100, max((L(:)-R(:)))/Rmax*100);
fprintf('  (full difference, after-rashi:     %+.3f .. %+.3f %%)\n', ...
        min((A(:)-R(:)))/Rmax*100, max((A(:)-R(:)))/Rmax*100);
close(f);
fprintf('--- done ---\n');
end

function rms_pct = pinRippleRms_probe(S, P)
% Local copy of the tool's ripple metric (the tool's own is a private local fn).
rms_pct = NaN;
D = S.dose.diff_pct;  R = S.dose.rashi_Gy;
if isempty(D), return; end
f = round(P.spacing_mm / P.voxel_mm);
if f < 2, return; end
[~, nx, ny] = size(D);
nx2 = nx - mod(nx,f);  ny2 = ny - mod(ny,f);
D = D(:,1:nx2,1:ny2);  R = R(:,1:nx2,1:ny2);
[nz, ~, ~] = size(D);
c = reshape(D, nz, f, nx2/f, ny2);  c = squeeze(mean(c,2));
c = reshape(c, nz, nx2/f, f, ny2/f); c = squeeze(mean(c,3));
c = repelem(c, 1, f, f);
r = D - c;
m = R > 0.5*max(R(:));
if any(m(:)), rms_pct = sqrt(mean(r(m).^2)); end
end
