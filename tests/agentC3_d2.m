function agentC3_d2()
%AGENTC3_D2  Agent C retest, defect D2: the pin-ripple field.
%   D2a  shows "-" (not a number) when no exact dose exists
%   D2b  the displayed value equals the exact-RaShi ripple, not the diff_pct one
%   D2c  grid independence: ~0.94 % at 1.0 mm AND at 0.5 mm (a physical quantity)
%   Run: matlab -batch "addpath('..'); agentC3_d2"

fprintf('\n================ AGENT C3 : D2 ================\n');

%% D2a -- no exact dose at all
fprintf('\n--- D2a: no exact dose -> must show "-" ---\n');
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'compareExact', 0);
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('calc2drm',  f);
drm2d_nonlocality_tool('applynl',   f);
S = guidata(f);
rl = strtrim(findLine(get(S.h.txt_info,'String'), 'pin ripple rms'));
fprintf('D2a ripple line                 : %s\n', rl);
fprintf('D2a is "-" (not a number)       : %d  (want 1)\n', contains(rl,'-  (tick'));
closeFigs();

%% D2b/D2c -- coarse then fine grid, with a current exact dose
for px = [1.0 0.5]
    fprintf('\n--- D2b/c: lateral pixel %.1f mm ---\n', px);
    g = drm2d_nonlocality_tool('new', 'Visible', 'off');
    drm2d_nonlocality_tool('set', g, 'compareExact', 1);
    drm2d_nonlocality_tool('set', g, 'hifi', px < 0.9);
    drm2d_nonlocality_tool('calcrashi', g);
    drm2d_nonlocality_tool('calc2drm',  g);
    S = guidata(g);

    shown = strtrim(findLine(get(S.h.txt_info,'String'), 'pin ripple rms'));
    R  = S.dose.rashi_Gy;
    fblk = round(S.P.spacing_mm / S.P.voxel_mm);
    rExact = rippleOf((S.dose.exact_Gy - R)/max(R(:))*100, R, fblk);
    rLocal = rippleOf((S.dose.local_Gy - R)/max(R(:))*100, R, fblk);
    if ~isempty(S.dose.diff_pct)
        rDiff = rippleOf(S.dose.diff_pct, R, fblk);
    else
        rDiff = NaN;
    end
    fprintf('  pixel %.2f mm | shown: %s\n', S.P.lateral_pixel_mm, shown);
    fprintf('  independent: exact-RaShi %.4f %% | local-RaShi %.4f %% | diff_pct %.4f %%\n', ...
            rExact, rLocal, rDiff);
    closeFigs();
end

fprintf('\n================ D2 DONE ================\n');
end

% ------------------------------------------------------------------ helpers
function rms_pct = rippleOf(D, R, f)
%RIPPLEOF  Independent re-implementation of the ripple arithmetic, so the
%   comparison tests the INPUT array rather than the formula.
rms_pct = NaN;
if f < 2, return; end
[~, nx, ny] = size(D);
nx2 = nx - mod(nx,f);  ny2 = ny - mod(ny,f);
if nx2 < f || ny2 < f, return; end
D = D(:,1:nx2,1:ny2);  R = R(:,1:nx2,1:ny2);
[nz, ~, ~] = size(D);
cell = reshape(D, nz, f, nx2/f, f, ny2/f);
cell = squeeze(mean(mean(cell, 2), 4));
cell = repelem(cell, 1, f, f);
res  = D - cell;
m    = R > 0.5*max(R(:));
if ~any(m(:)), return; end
rms_pct = sqrt(mean(res(m).^2));
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
