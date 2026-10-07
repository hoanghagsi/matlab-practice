function agentB_smoke()
%AGENTB_SMOKE  Fast end-to-end smoke test of the PLAN2 five-button workflow.
%   Small geometry (fewer spots, fewer levels) so it runs in seconds.
%   Run:  matlab -batch "addpath('..'); agentB_smoke"
addpath(fileparts(fileparts(mfilename('fullpath'))));
fprintf('--- Agent B smoke test ---\n');

t0 = tic;
f = drm2d_nonlocality_tool('new', 'Visible', 'off', ...
        'widthA_mm', 6, 'widthB_mm', 6, 'fieldX_mm', 6, ...
        'heightA_mm', 12, 'heightB_mm', 8);
fprintf('build GUI                      %.1f s\n', toc(t0));

S = guidata(f);
req = {'btn_rashi','btn_2drm','btn_diff','btn_apply','btn_result','btn_reset','txt_info'};
for i = 1:numel(req)
    assert(isfield(S.h, req{i}) && ishandle(S.h.(req{i})), 'missing %s', req{i});
end
fprintf('all six buttons + info box     OK\n');

assert(strcmpi(get(S.h.btn_diff,'Enable'),'off'),  'btn_diff should start disabled');
assert(strcmpi(get(S.h.btn_apply,'Enable'),'off'), 'btn_apply should start disabled');
fprintf('initial enable state           OK\n');

t0 = tic; drm2d_nonlocality_tool('calcrashi', f);
fprintf('calcrashi                      %.1f s\n', toc(t0));
t0 = tic; drm2d_nonlocality_tool('calc2drm', f);
fprintf('calc2drm                       %.1f s\n', toc(t0));

S = guidata(f);
assert(~isempty(S.dose.rashi_Gy), 'no rashi dose');
assert(~isempty(S.dose.local_Gy), 'no local dose');
assert(strcmpi(get(S.h.btn_diff,'Enable'),'on'), 'btn_diff should now be enabled');

t0 = tic; drm2d_nonlocality_tool('seediff', f);
fprintf('seediff                        %.1f s\n', toc(t0));
S = guidata(f);
d = S.dose.diff_pct;
fprintf('   difference BEFORE apply  %+.3f .. %+.3f %% (material term only)\n', ...
        min(d(:)), max(d(:)));

t0 = tic; drm2d_nonlocality_tool('applynl', f);
fprintf('applynl                        %.1f s\n', toc(t0));
S = guidata(f);
d = S.dose.diff_pct;
fprintf('   difference AFTER  apply  %+.3f .. %+.3f %%\n', min(d(:)), max(d(:)));
assert(isequal(S.dose.after_Gy, S.dose.local_Gy + S.dose.nl_Gy), ...
       'after_Gy must be local + nl');

t0 = tic; H = drm2d_nonlocality_tool('result', f);
fprintf('result (%d figures)             %.1f s\n', numel(H), toc(t0));
for i = 1:numel(H)
    assert(ishandle(H(i)), 'bad figure handle %d', i);
    fprintf('   fig %d: %s\n', i, get(H(i), 'Name'));
end
close(H);

drm2d_nonlocality_tool('reset', f);
S = guidata(f);
assert(~isempty(S.dose.rashi_Gy) && ~isempty(S.dose.local_Gy), ...
       'reset must keep both doses');
assert(isempty(S.dose.nl_Gy) && isempty(S.dose.diff_pct), ...
       'reset must clear the apply state');
fprintf('reset keeps doses, clears apply OK\n');

txt = get(guidata(f).h.txt_info, 'String');
if ~iscell(txt), txt = cellstr(txt); end
fprintf('--- info box ---\n');
fprintf('%s\n', txt{:});

close(f);
fprintf('--- SMOKE TEST PASSED ---\n');
end
