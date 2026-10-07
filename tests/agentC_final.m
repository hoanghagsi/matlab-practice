function ok = agentC_final()
%AGENTC_FINAL  Remaining Agent C coverage: the three untouched controls,
%   the compareExact feature, and the stale-axes half of T05.

np = 0; nf = 0;
    function check(id, name, tf, detail)
        if nargin < 4, detail = ''; end
        if tf, np = np + 1; v = 'PASS'; else, nf = nf + 1; v = 'FAIL'; end
        fprintf('  %s  %-6s %-48s %s\n', v, id, name, detail);
    end

fprintf('\n===== Agent C final coverage =====\n');

%% controls not exercised anywhere yet: edt_wB, edt_fx, pop_expand
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
e = '';
try
    drm2d_nonlocality_tool('set', f, 'widthB_mm', 12);
    S = drm2d_nonlocality_tool('state', f);
    okB = (S.P.widthB_mm == 12);
catch ME, e = ME.message; okB = false; end
check('T03', 'widthB edit fires + takes effect', okB && isempty(e), e);

e = '';
try
    drm2d_nonlocality_tool('set', f, 'fieldX_mm', 24);
    S = drm2d_nonlocality_tool('state', f);
    okX = (S.P.fieldX_mm == 24);
catch ME, e = ME.message; okX = false; end
check('T03', 'fieldX edit fires + takes effect', okX && isempty(e), ...
      sprintf('fieldX=%g', S.P.fieldX_mm));

e = '';
try
    drm2d_nonlocality_tool('set', f, 'expand_mode', 'gauss');
    S1 = drm2d_nonlocality_tool('state', f);
    drm2d_nonlocality_tool('set', f, 'expand_mode', 'replicate');
    S2 = drm2d_nonlocality_tool('state', f);
    okE = strcmpi(S1.P.expand_mode,'gauss') && strcmpi(S2.P.expand_mode,'replicate');
catch ME, e = ME.message; okE = false; end
check('T03', 'expand_mode popup fires both ways', okE && isempty(e), e);

% default must be replicate (user-confirmed decision)
f2 = drm2d_nonlocality_tool('new', 'Visible', 'off');
Sd = drm2d_nonlocality_tool('state', f2);
check('cfg', 'default expand_mode is replicate', strcmpi(Sd.P.expand_mode, 'replicate'), Sd.P.expand_mode);
check('cfg', 'default energy is 240 MeV/u', Sd.P.energy_MeVu == 240, sprintf('%g', Sd.P.energy_MeVu));
check('cfg', 'n_per_spot_layer fixed at 5000', Sd.P.n_per_spot_layer == 5000, sprintf('%g', Sd.P.n_per_spot_layer));
close(f2); close(f);

%% T05 second half: dose axes visually greyed when stale
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('calculate', f);
h = guidata(f).h;
axColFresh = get(h.ax_before, 'Color');
drm2d_nonlocality_tool('set', f, 'heightB_mm', 22);
h = guidata(f).h;
axColStale = get(h.ax_before, 'Color');
check('T05', 'dose axes change appearance when stale', ~isequal(axColFresh, axColStale), ...
      sprintf('fresh=%s stale=%s', mat2str(axColFresh,3), mat2str(axColStale,3)));
close(f);

%% compareExact must actually compute an exact 2DRM dose
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'compareExact', true);
drm2d_nonlocality_tool('calculate', f);
drm2d_nonlocality_tool('applynl', f);
S = drm2d_nonlocality_tool('state', f);
fn = fieldnames(S.dose);
fprintf('    dose fields: %s\n', strjoin(fn', ', '));
hasExact = isfield(S.dose, 'exact2drm_Gy') && ~isempty(S.dose.exact2drm_Gy);
check('T03', 'compareExact produces an exact 2DRM dose', hasExact);
if hasExact
    dm = S.dose.exact2drm_Gy;  da = S.dose.after_Gy;
    rel = max(abs(da(:)-dm(:))) / max(abs(dm(:)));
    check('mdl', 'model vs exact 2DRM residual reported', isfinite(rel), ...
          sprintf('relmax(model, exact) = %.4g', rel));
end
close(f);

%% independent D2 check across orderings, outside the tool's own assertion
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
pairs = [60 40; 40 40; 30 50; 1 60; 60 1; 20 20];
allZero = true; worst = 0;
for i = 1:size(pairs,1)
    drm2d_nonlocality_tool('set', f, 'heightA_mm', pairs(i,1), 'heightB_mm', pairs(i,2));
    drm2d_nonlocality_tool('calculate', f);
    drm2d_nonlocality_tool('applynl', f);
    S = drm2d_nonlocality_tool('state', f);
    % sum over levels of dPhi must vanish -> here checked via dose: K_A=K_B gives 0
    nlmax = max(abs(S.dose.nl_Gy(:)));
    if pairs(i,1) == pairs(i,2) && nlmax > 0, allZero = false; end
    worst = max(worst, nlmax);
    fprintf('    K_A=%2d K_B=%2d : max|dD| = %.4g Gy\n', pairs(i,1), pairs(i,2), nlmax);
end
check('T15', 'K_A=K_B always gives exactly zero dD', allZero);
close(f);

fprintf('-----------------------------------------\n%d passed, %d failed\n', np, nf);
ok = (nf == 0);
end
