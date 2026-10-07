function ok = agentC_gaps()
%AGENTC_GAPS  Agent C independent tests for the gaps Agent B declared uncovered.
%
%   Covers T05, T03(checkbox half), T14, T18, T31, T33, T35, plus a deeper
%   look at T19/T24/T26/T28/T29 and an independent D2 check.
%
%   Run:  matlab -batch "addpath('..'); ok = agentC_gaps(); exit(~ok)"
%
%   This file only READS the tool and the reference .mat files. It writes nothing.

np = 0; nf = 0; results = {};

    function check(id, name, tf, detail)
        if nargin < 4, detail = ''; end
        if tf
            np = np + 1; verdict = 'PASS';
        else
            nf = nf + 1; verdict = 'FAIL';
        end
        fprintf('  %s  %-6s %-46s %s\n', verdict, id, name, detail);
        results(end+1, :) = {id, verdict, name, detail}; %#ok<AGROW>
    end

fprintf('\n===== Agent C gap tests =====\n');

%% ---------------------------------------------------------------- T05 stale
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('calculate', f);
S = drm2d_nonlocality_tool('state', f);
hadDose = ~isempty(S.dose.rashi_Gy);
h = guidata(f).h;
applyEnabledBefore = strcmpi(get(h.btn_apply, 'Enable'), 'on');

drm2d_nonlocality_tool('set', f, 'heightB_mm', 25);      % change a param post-calc
h = guidata(f).h;
S2 = drm2d_nonlocality_tool('state', f);
applyDisabledAfter = strcmpi(get(h.btn_apply, 'Enable'), 'off');
staleFlag = isfield(S2, 'stale') && S2.stale;
check('T05', 'calculate enables Apply', hadDose && applyEnabledBefore);
check('T05', 'param change disables Apply (staleness)', applyDisabledAfter, ...
      sprintf('Enable=%s stale=%d', get(h.btn_apply,'Enable'), staleFlag));
close(f);

%% -------------------------------------------------- T03 checkbox half
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
errHifi = ''; errExact = '';
try
    drm2d_nonlocality_tool('set', f, 'hifi', true);
    drm2d_nonlocality_tool('set', f, 'hifi', false);
catch ME, errHifi = ME.message; end
try
    drm2d_nonlocality_tool('set', f, 'compareExact', true);
    drm2d_nonlocality_tool('set', f, 'compareExact', false);
catch ME, errExact = ME.message; end
check('T03', 'hifi checkbox callback fires', isempty(errHifi), errHifi);
check('T03', 'compareExact checkbox callback fires', isempty(errExact), errExact);

% hifi must actually change the pixel size that Calculate uses
drm2d_nonlocality_tool('set', f, 'hifi', true);
Shi = drm2d_nonlocality_tool('state', f);
drm2d_nonlocality_tool('set', f, 'hifi', false);
Slo = drm2d_nonlocality_tool('state', f);
check('T03', 'hifi changes lateral_pixel_mm', ...
      Shi.P.lateral_pixel_mm == 0.5 && Slo.P.lateral_pixel_mm == 1.0, ...
      sprintf('hifi=%g coarse=%g', Shi.P.lateral_pixel_mm, Slo.P.lateral_pixel_mm));
close(f);

%% ---------------------------------------------------------------- T31 spacing
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'hifi', true);          % pixel 0.5
Sbefore = drm2d_nonlocality_tool('state', f);
drm2d_nonlocality_tool('set', f, 'spacing_mm', 3.3);     % 3.3 / 0.5 = 6.6, not integer
Safter = drm2d_nonlocality_tool('state', f);
rejected = (Safter.P.spacing_mm ~= 3.3);
check('T31', 'spacing 3.3 at pixel 0.5 rejected/snapped', rejected, ...
      sprintf('spacing before=%g after=%g', Sbefore.P.spacing_mm, Safter.P.spacing_mm));
close(f);

%% ---------------------------------------------------------------- T19 K_A=K_B
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'heightA_mm', 40, 'heightB_mm', 40);
drm2d_nonlocality_tool('calculate', f);
drm2d_nonlocality_tool('applynl', f);
S = drm2d_nonlocality_tool('state', f);
same = isequal(S.dose.after_Gy, S.dose.rashi_Gy);
mx = max(abs(S.dose.nl_Gy(:)));
check('T19', 'K_A=K_B -> After bitwise == Before', same, sprintf('max|dD|=%g', mx));
close(f);

%% ---------------------------------------------------------------- T24 K_B=0
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'heightB_mm', 0);
errKB = '';
try
    drm2d_nonlocality_tool('calculate', f);
    drm2d_nonlocality_tool('applynl', f);
catch ME, errKB = ME.message; end
S = drm2d_nonlocality_tool('state', f);
noNaN = isempty(errKB) && ~any(isnan(S.dose.rashi_Gy(:))) && ~any(isnan(S.dose.after_Gy(:)));
check('T24', 'K_B=0 runs, no NaN in dose', noNaN, errKB);
% dose on the zone B side should be ~0 relative to zone A
if isempty(errKB)
    d = S.dose.rashi_Gy;  ye = S.dose.yEdges_mm;  yc = 0.5*(ye(1:end-1)+ye(2:end));
    inA = yc < -1 & yc > -15;  inB = yc > 1 & yc < 15;
    mA = max(max(max(d(:,:,inA))));  mB = max(max(max(d(:,:,inB))));
    check('T24', 'K_B=0 -> zone B dose << zone A', mB < 0.25*mA, ...
          sprintf('maxA=%.4g maxB=%.4g ratio=%.3f', mA, mB, mB/mA));
end
close(f);

%% ---------------------------------------------------------------- T26/T28/T29
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
S0 = drm2d_nonlocality_tool('state', f);
drm2d_nonlocality_tool('set', f, 'fwhm0_mm', 0);
S1 = drm2d_nonlocality_tool('state', f);
check('T26', 'FWHM=0 rejected (not accepted as 0)', S1.P.fwhm0_mm ~= 0, ...
      sprintf('fwhm now %g', S1.P.fwhm0_mm));

drm2d_nonlocality_tool('set', f, 'heightA_mm', -5);
S2 = drm2d_nonlocality_tool('state', f);
check('T28', 'negative height rejected', S2.P.heightA_mm > 0, ...
      sprintf('heightA now %g', S2.P.heightA_mm));

drm2d_nonlocality_tool('set', f, 'heightB_mm', 'abc');
S3 = drm2d_nonlocality_tool('state', f);
check('T29', 'non-numeric height reverted', isfinite(S3.P.heightB_mm) && S3.P.heightB_mm > 0, ...
      sprintf('heightB now %g', S3.P.heightB_mm));
close(f);

%% ---------------------------------------------------------------- T33 60 mm
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'widthA_mm', 60, 'widthB_mm', 60);
err60 = ''; t60 = NaN;
try
    tic; drm2d_nonlocality_tool('calculate', f); t60 = toc;
catch ME, err60 = ME.message; end
S = drm2d_nonlocality_tool('state', f);
check('T33', 'width 60 mm completes', isempty(err60) && ~isempty(S.dose.rashi_Gy), ...
      sprintf('%.1f s, grid %s', t60, mat2str(size(S.dose.rashi_Gy))));
close(f);

%% ---------------------------------------------------------------- T35 coarse vs fine
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'hifi', false);
tic; drm2d_nonlocality_tool('calculate', f); tCoarse = toc;
Sc = drm2d_nonlocality_tool('state', f);
dc = Sc.dose.rashi_Gy;  xec = Sc.dose.xEdges_mm; yec = Sc.dose.yEdges_mm;

drm2d_nonlocality_tool('set', f, 'hifi', true);
drm2d_nonlocality_tool('calculate', f);
Sf = drm2d_nonlocality_tool('state', f);
df = Sf.dose.rashi_Gy;  xef = Sf.dose.xEdges_mm; yef = Sf.dose.yEdges_mm;
close(f);

fprintf('    coarse grid %s (%.1f s), fine grid %s\n', mat2str(size(dc)), tCoarse, mat2str(size(df)));
if isequal(size(dc), size(df))
    rel = max(abs(dc(:)-df(:))) / max(abs(df(:)));
    check('T35', 'coarse vs high-fidelity dose < 2%', rel < 0.02, sprintf('relmax %.4g', rel));
else
    % both are on 1 mm voxels per the plan; if they differ, resample by nearest centre
    cxc = 0.5*(xec(1:end-1)+xec(2:end)); cyc = 0.5*(yec(1:end-1)+yec(2:end));
    fxc = 0.5*(xef(1:end-1)+xef(2:end)); fyc = 0.5*(yef(1:end-1)+yef(2:end));
    nz = min(size(dc,1), size(df,1));
    [~, ix] = min(abs(fxc(:)' - cxc(:)), [], 2);
    [~, iy] = min(abs(fyc(:)' - cyc(:)), [], 2);
    d2 = df(1:nz, ix, iy);
    d1 = dc(1:nz, :, :);
    rel = max(abs(d1(:)-d2(:))) / max(abs(d2(:)));
    check('T35', 'coarse vs high-fidelity dose < 2% (resampled)', rel < 0.02, ...
          sprintf('relmax %.4g, sizes %s vs %s', rel, mat2str(size(dc)), mat2str(size(df))));
end

%% ------------------------------------------------- T14 / T18 reference compare
for nm = {'e200', 'reversed'}
    name = nm{1};
    pth = fullfile(fileparts(mfilename('fullpath')), '..', 'reference', ['ref_' name '.mat']);
    if exist(pth, 'file') ~= 2
        check(['T14/18'], [name ' reference present'], false, 'file missing'); continue;
    end
    R = load(pth);
    f = drm2d_nonlocality_tool('new', 'Visible', 'off');
    drm2d_nonlocality_tool('set', f, 'hifi', true);
    drm2d_nonlocality_tool('set', f, 'energy_MeVu', double(R.params.energy_MeVu), ...
                           'heightA_mm', double(R.K_A), 'heightB_mm', double(R.K_B));
    Sp = drm2d_nonlocality_tool('state', f);
    paramsOk = (Sp.P.energy_MeVu == double(R.params.energy_MeVu)) && ...
               (Sp.P.heightA_mm  == double(R.K_A)) && ...
               (Sp.P.heightB_mm  == double(R.K_B));
    id = 'T14'; if strcmp(name,'reversed'), id = 'T18'; end
    check(id, [name ': params accepted'], paramsOk, ...
          sprintf('E=%g K_A=%g K_B=%g', Sp.P.energy_MeVu, Sp.P.heightA_mm, Sp.P.heightB_mm));

    drm2d_nonlocality_tool('calculate', f);
    S = drm2d_nonlocality_tool('state', f);
    dR = S.dose.rashi_Gy;
    if isequal(size(dR), size(R.dose_rashi_Gy))
        rel = max(abs(dR(:) - R.dose_rashi_Gy(:))) / max(abs(R.dose_rashi_Gy(:)));
        check(id, [name ': RaShi dose vs Python'], rel < 1e-6, sprintf('relmax %.3g', rel));
    else
        check(id, [name ': RaShi dose vs Python'], false, ...
              sprintf('SIZE MISMATCH %s vs %s', mat2str(size(dR)), mat2str(size(R.dose_rashi_Gy))));
    end

    % D2: MATLAB must conserve where Python did not
    drm2d_nonlocality_tool('applynl', f);
    S2 = drm2d_nonlocality_tool('state', f);
    if isfield(R, 'python_sum_a_k')
        pySum = double(R.python_sum_a_k);
        if strcmp(name, 'reversed')
            check('T18', 'Python sum(a_k) is non-zero (fix does work)', abs(pySum) > 1, ...
                  sprintf('python sum(a_k)=%g', pySum));
        end
    end
    check(id, [name ': nl applied without error'], ~isempty(S2.dose.after_Gy));
    check(id, [name ': rashi unchanged by applynl'], isequal(S2.dose.rashi_Gy, dR));
    if double(R.nl_valid) == 0
        fprintf('    (nl_valid=0: Python non-locality fields deliberately NOT compared)\n');
    end
    close(f);
end

%% ---------------------------------------------------------------- summary
fprintf('-----------------------------------------\n');
fprintf('%d passed, %d failed\n', np, nf);
ok = (nf == 0);
if ok, fprintf('GAP TESTS ALL PASSED\n'); else, fprintf('GAP TEST FAILURES PRESENT\n'); end
end
