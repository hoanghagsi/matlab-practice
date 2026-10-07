function agentC_probe()
%AGENTC_PROBE  Follow-up investigation of the three failures in agentC_gaps.
%   Determines whether each is a defect in the tool or an error in my test.

fprintf('\n===== PROBE 1: T24 zone B dose profile with K_B = 0 =====\n');
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'heightB_mm', 0);
drm2d_nonlocality_tool('calculate', f);
S = drm2d_nonlocality_tool('state', f);
d = S.dose.rashi_Gy;  ye = S.dose.yEdges_mm;  yc = 0.5*(ye(1:end-1)+ye(2:end));
% max over z and x for each y
prof = squeeze(max(max(d, [], 1), [], 2));
fprintf('  y [mm] :');  fprintf(' %6.1f', yc(abs(yc) <= 18));  fprintf('\n');
fprintf('  maxDose:');  fprintf(' %6.4f', prof(abs(yc) <= 18)); fprintf('\n');
mA = max(prof(yc < -1 & yc > -15));
fprintf('  zone A max   = %.5f Gy\n', mA);
fprintf('  zone B y>1   = %.5f Gy (ratio %.3f)\n', max(prof(yc>1  & yc<15)), max(prof(yc>1  & yc<15))/mA);
fprintf('  zone B y>8   = %.5f Gy (ratio %.3f)\n', max(prof(yc>8  & yc<15)), max(prof(yc>8  & yc<15))/mA);
fprintf('  far  y>20    = %.5f Gy (ratio %.3f)\n', max(prof(yc>20)),        max(prof(yc>20))/mA);
% sanity: are there any ions assigned to zone B spots?
fprintf('  K_B levels   = %g (expect 0)\n', S.P.heightB_mm);
close(f);

fprintf('\n===== PROBE 2: T28 negative height behaviour =====\n');
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
S0 = drm2d_nonlocality_tool('state', f);
fprintf('  before: heightA = %g\n', S0.P.heightA_mm);
drm2d_nonlocality_tool('set', f, 'heightA_mm', -5);
S1 = drm2d_nonlocality_tool('state', f);
fprintf('  after set -5: heightA = %g   (plan T28: previous value restored -> expect 60)\n', S1.P.heightA_mm);
fprintf('  edit box now reads: "%s"\n', get(guidata(f).h.edt_hA, 'String'));
% compare with how negative WIDTH behaves (selftest covers that one and it passes)
drm2d_nonlocality_tool('set', f, 'widthA_mm', -5);
S2 = drm2d_nonlocality_tool('state', f);
fprintf('  after width -5: widthA  = %g   (selftest expects reset to 3)\n', S2.P.widthA_mm);
close(f);

fprintf('\n===== PROBE 3: T35 coarse vs fine, with CORRECT 1 mm voxel averaging =====\n');
f = drm2d_nonlocality_tool('new', 'Visible', 'off');
drm2d_nonlocality_tool('set', f, 'hifi', false);
drm2d_nonlocality_tool('calculate', f);
Sc = drm2d_nonlocality_tool('state', f);
dc = Sc.dose.rashi_Gy;
fprintf('  coarse: pixel %g mm, dose size %s\n', Sc.P.lateral_pixel_mm, mat2str(size(dc)));

drm2d_nonlocality_tool('set', f, 'hifi', true);
drm2d_nonlocality_tool('calculate', f);
Sf = drm2d_nonlocality_tool('state', f);
df = Sf.dose.rashi_Gy;
fprintf('  fine  : pixel %g mm, dose size %s\n', Sf.P.lateral_pixel_mm, mat2str(size(df)));
close(f);

% Correct comparison: block-average the fine dose down to the coarse 1 mm pixels.
fac = round(Sc.P.lateral_pixel_mm / Sf.P.lateral_pixel_mm);
fprintf('  block-averaging fine by factor %d in x and y\n', fac);
sz = size(df);
dfb = reshape(df, sz(1), fac, sz(2)/fac, fac, sz(3)/fac);
dfb = squeeze(mean(mean(dfb, 2), 4));
fprintf('  fine after averaging: %s\n', mat2str(size(dfb)));
if isequal(size(dc), size(dfb))
    rel = max(abs(dc(:) - dfb(:))) / max(abs(dfb(:)));
    inside = false(size(dc));
    yc = 0.5*(Sc.dose.yEdges_mm(1:end-1) + Sc.dose.yEdges_mm(2:end));
    xc = 0.5*(Sc.dose.xEdges_mm(1:end-1) + Sc.dose.xEdges_mm(2:end));
    inside(:, abs(xc) < 15, abs(yc) < 15) = true;
    relIn = max(abs(dc(inside) - dfb(inside))) / max(abs(dfb(inside)));
    fprintf('  relmax whole grid = %.4g   (criterion 0.02)\n', rel);
    fprintf('  relmax in-field   = %.4g\n', relIn);
else
    fprintf('  SIZE MISMATCH after averaging: %s vs %s\n', mat2str(size(dc)), mat2str(size(dfb)));
end

fprintf('\n===== PROBE 4: does the GUI ever display 1 mm voxels? =====\n');
fprintf('  P.voxel_mm = %g\n', Sc.P.voxel_mm);
fprintf('  coarse dose dims vs pixel grid: %s\n', mat2str(size(dc)));
fprintf('  (plan Sect.8 says dose is (nz,nx,ny) on the PIXEL grid; 1 mm voxels only in analysis)\n');
end
