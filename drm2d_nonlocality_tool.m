function varargout = drm2d_nonlocality_tool(varargin)
%DRM2D_NONLOCALITY_TOOL  Interactive demonstrator of the 2DRM non-locality model.
%
%   Ports analytic_model/ (config, physics, geometry, fluence, dose, nonlocality)
%   from Python.  See matlab/PLAN.md for the contract this file implements.
%
%   UNITS.  Every length is mm, energy MeV/u, dose Gy, angle rad, mass thickness
%   g/cm^2.  Variable names carry the unit as a suffix (_mm, _MeVu, _Gy, _rad,
%   _gcm2) exactly as in the Python code.
%
%   COORDINATES.
%       z : beam direction, depth in the water phantom (z = 0 at phantom entrance)
%       y : across the zone boundary (boundary at y = 0); Region A at y < 0,
%           Region B at y > 0
%       x : along the zone boundary
%
%   THE SIX BUTTONS  (PLAN2.md section 1).  Each adds exactly ONE physical
%   effect, so the chain reads:
%
%       D_RaShi  --[material]-->  D_2DRM(local)  --[non-locality]-->  D_2DRM(exact)
%
%       "Calculate dose (RaShi)"    -> RaShi dose, water transport (lp_R)
%       "Calculate dose (2DRM)"     -> LOCAL 2DRM dose: the SAME fluence as the
%                                      RaShi plan (identity P1 below) but PMMA
%                                      transport (lp_M).  Differs from RaShi
%                                      through the material term ONLY (~+1 %).
%       "See difference"            -> (local - rashi) / max(rashi)        [%]
%       "Apply non-locality model"  -> adds dD_NL to the LOCAL 2DRM dose:
%                                      (local + dD_NL - rashi) / max(rashi) [%]
%       "Result"                    -> up to 11 pop-up figures, selectable via
%                                      the listbox (PLAN2.md section 5, grown
%                                      to 11 per PLAN3.md section 6.4)
%       "Reset"                     -> clears the Apply-derived state only;
%                                      both calculated doses survive.
%
%   IDENTITY P1 (PLAN2.md section 0).  A local 2DRM modulates each spot by its
%   own pin only.  Spot i sits in zone Z(i) whose pin carries W_i = N0*K_Z(i)
%   ions spread uniformly over levels 1..K_Z(i), so
%
%       F_local_k = sum_i W_i G_i 1(k<=K_Z)/K_Z = sum_i N0 G_i 1(k<=K_Z) = F_R_k
%
%   exactly.  Non-locality is therefore the ONLY fluence difference between the
%   two plans; the local 2DRM reuses fluenceRashi and only swaps lp_R -> lp_M.
%
%   The RaShi and local-2DRM doses are immutable originals; Apply recomputes
%   dD from scratch every press and never writes to either (assertGuard).
%
%   USAGE (GUI)
%       drm2d_nonlocality_tool
%
%   USAGE (programmatic, for headless testing -- PLAN.md 7 / PLAN2.md 6)
%       f  = drm2d_nonlocality_tool('new','Visible','off','energy_MeVu',240)
%       drm2d_nonlocality_tool('set', f, 'heightB_mm', 20)
%       drm2d_nonlocality_tool('calcrashi', f)   % 'calculate' is an alias
%       drm2d_nonlocality_tool('calc2drm',  f)
%       drm2d_nonlocality_tool('seediff',   f)
%       drm2d_nonlocality_tool('applynl',   f)
%       h  = drm2d_nonlocality_tool('result', f) % all 11 figures (PLAN3.md section 6)
%       h  = drm2d_nonlocality_tool('result', f, {'fig3_dose_maps_yz','fig7_dD_xy'})
%                                             % a subset, by resultFigureKeys() name
%       drm2d_nonlocality_tool('savefigs', f, outDir) % PNG export, PLAN3.md section 2.2
%       drm2d_nonlocality_tool('reset',     f)
%       S  = drm2d_nonlocality_tool('state', f)
%       ok = drm2d_nonlocality_tool('selftest')
%
%   Headless:  matlab -batch "ok=drm2d_nonlocality_tool('selftest'); exit(~ok)"

if nargin == 0
    varargout{1} = apiNew('Visible', 'on');
    return;
end

cmd = varargin{1};
if ~(ischar(cmd) || isstring(cmd))
    error('drm2d:badCall', 'First argument must be a command string.');
end

switch lower(char(cmd))
    case 'new',        varargout{1} = apiNew(varargin{2:end});
    case 'set',        apiSet(varargin{2}, varargin{3:end});
    case 'calcrashi',  onCalcRashi(varargin{2});
    case 'calculate',  onCalcRashi(varargin{2});   % round-1 alias (keeps T01-T35)
    case 'calc2drm',   onCalc2drmLocal(varargin{2});
    case 'seediff',    onSeeDifference(varargin{2});
    case 'applynl',    onApplyNonlocality(varargin{2});
    case 'result',     h = onResult(varargin{2:end});
                       if nargout > 0, varargout{1} = h; end
    case 'savefigs',   onSaveFigs(varargin{2:end});
    case 'reset',      onReset(varargin{2});
    case 'state',      varargout{1} = apiState(varargin{2});
    case 'selftest',   ok = selfTest(varargin{2:end});
                       if nargout > 0, varargout{1} = ok; end
    otherwise
        error('drm2d:badCmd', 'Unknown command "%s".', char(cmd));
end
end


%% ====================================================================== API

function fig = apiNew(varargin)
%APINEW  Build the GUI, optionally overriding parameters.
%   apiNew('Visible','off', 'energy_MeVu',240, 'fwhm0_mm',6, ...)
vis = 'on';
over = struct();
k = 1;
while k < numel(varargin)
    name = varargin{k};
    val  = varargin{k+1};
    if strcmpi(name, 'Visible')
        vis = val;
    else
        over.(char(name)) = val;
    end
    k = k + 2;
end

P = defaultParams();
fn = fieldnames(over);
for i = 1:numel(fn)
    P.(fn{i}) = over.(fn{i});
end
P = validateParams(P);           % silent clamp of anything the caller passed

fig = buildGui(P, vis);
updateGeometryPlot(fig);
end


function apiSet(fig, varargin)
%APISET  Set one or more GUI fields and fire the change callback.
S = guidata(fig);
k = 1;
while k < numel(varargin)
    name = char(varargin{k});
    val  = varargin{k+1};
    switch name
        case 'energy_MeVu'
            idx = find(abs(S.energies_MeVu - val) < 1e-9, 1);
            if isempty(idx)
                % Not one of the 9 tabulated DDD energies -> reject (T32).
                setStatus(fig, 'Energy %g MeV/u rejected: not a tabulated value (%s).', ...
                          val, mat2str(S.energies_MeVu));
            else
                set(S.h.pop_energy, 'Value', idx);
            end
        case 'expand_mode'
            idx = find(strcmpi(S.expandModes, val), 1);
            if ~isempty(idx), set(S.h.pop_expand, 'Value', idx); end
        case 'hifi'
            set(S.h.chk_hifi, 'Value', double(logical(val)));
        case 'compareExact'
            set(S.h.chk_exact, 'Value', double(logical(val)));
        otherwise
            tag = paramTag(name);
            if isempty(tag)
                error('drm2d:badField', 'Unknown settable field "%s".', name);
            end
            if ischar(val) || isstring(val)
                set(S.h.(tag), 'String', char(val));     % lets tests inject "abc"
            else
                set(S.h.(tag), 'String', num2str(val, '%g'));
            end
    end
    k = k + 2;
end
onParamChanged(fig);
end


function S = apiState(fig)
%APISTATE  Deep copy of the state struct (handles stripped) for testing.
S = guidata(fig);
if isfield(S, 'h'), S = rmfield(S, 'h'); end
end


function tag = paramTag(name)
%PARAMTAG  Map a parameter name to its uicontrol tag.
map = { 'fwhm0_mm','edt_fwhm'; 'widthA_mm','edt_wA'; 'heightA_mm','edt_hA'; ...
        'widthB_mm','edt_wB'; 'heightB_mm','edt_hB'; 'fieldX_mm','edt_fx'; ...
        'spacing_mm','edt_D' };
i = find(strcmp(map(:,1), name), 1);
if isempty(i), tag = ''; else, tag = map{i,2}; end
end


%% =============================================================== PARAMETERS

function P = defaultParams()
%DEFAULTPARAMS  All defaults, taken verbatim from analytic_model/config.py.

% ---- beam (GUI) ----
P.energy_MeVu      = 240.0;   % one of the 9 tabulated DDD energies
P.fwhm0_mm         = 6.0;     % FWHM at the device entrance, parallel beam
P.n_per_spot_layer = 5000.0;  % 12C ions per spot and layer (FIXED, pure dose scale)

% ---- geometry in mm (GUI) ----
P.widthA_mm   = 15.0;         % Region A lateral y-extent
P.heightA_mm  = 60.0;         % Region A thickness [mm WEPL]
P.widthB_mm   = 15.0;         % Region B lateral y-extent
P.heightB_mm  = 40.0;         % Region B thickness [mm WEPL]
P.fieldX_mm   = 30.0;         % field extent along x
P.spacing_mm  = 3.0;          % spot spacing = pin period

% ---- RaShi plan ----
P.step_wepl_mm    = 1.0;      % one RaShi step = 1 mm WEPL
P.rashi_material  = 'water';

% ---- 2DRM ----
P.height_scale          = 1.162;   % pin step height = step_wepl / height_scale [mm PMMA]
P.pmma_density          = 1.162;
P.pmma_wer_mode         = 'nominal';
P.base_thickness_mm     = 0.0;
P.pmma_X0_gcm2          = 40.55;
P.level_offset_match    = true;
P.stair_pins            = true;
P.design_restrictions   = false;
P.gauss_expand          = true;
P.expand_mode           = 'replicate';   % GUI default (user-confirmed)
P.expand_sigma_mm       = 2.5;
P.expand_size_thresh    = 0.002;
P.expand_min_rel_weight = 0.01;
P.pin_tips_upstream     = true;

% ---- beam line ----
P.gap_mm           = 600.0;   % device downstream face -> phantom entrance
P.gap_material     = 'air';
P.include_air_wepl = true;

% ---- physics switches ----
P.device_scattering = true;
P.air_scattering    = true;
P.phantom_lateral   = true;
P.I_water_eV        = 75.0;

% ---- numerics ----
P.lateral_pixel_mm  = 1.0;    % COARSE default; high fidelity switches to 0.5
P.lateral_margin_mm = 25.0;
P.dz_fine_mm        = 0.1;
P.dz_node_mm        = 2.0;
P.z_max_mm          = 0.0;    % 0 -> auto (Bragg peak + 30 mm)
P.voxel_mm          = 1.0;

here = fileparts(mfilename('fullpath'));
P.basedata_dir = fullfile(fileparts(here), 'BaseDataOfGSI', 'carbon');
end


function [P, msgs, ok] = validateParams(Praw, Pprev)
%VALIDATEPARAMS  Clamp / snap everything and report what was changed.
%   ok = false means the parameters cannot produce a dose (caller must refuse).
%   Pprev (optional): the last-accepted parameter set, used by snapWidth/
%   snapHeight to RESTORE on bad input (DEFECT-2, DEFECTS.md -- FIXED) rather
%   than clamping to an arbitrary floor.  Defaults to defaultParams() so the
%   first-ever validation (apiNew, with no prior accepted state) still has a
%   sane value to fall back to.
if nargin < 2 || isempty(Pprev)
    Pprev = defaultParams();
end
P    = Praw;
msgs = {};
ok   = true;

% --- FWHM: 6..10 mm, and strictly > 0 (sigma = 0 makes every Gaussian degenerate)
if ~isfinite(P.fwhm0_mm) || P.fwhm0_mm <= 0
    msgs{end+1} = 'FWHM must be > 0 mm (sigma = 0 is degenerate); reset to 6 mm.';
    P.fwhm0_mm = 6.0;
elseif P.fwhm0_mm < 6.0
    msgs{end+1} = sprintf('FWHM %.3g mm clamped to the 6-10 mm range -> 6 mm.', P.fwhm0_mm);
    P.fwhm0_mm = 6.0;
elseif P.fwhm0_mm > 10.0
    msgs{end+1} = sprintf('FWHM %.3g mm clamped to the 6-10 mm range -> 10 mm.', P.fwhm0_mm);
    P.fwhm0_mm = 10.0;
end

% --- spot spacing: > 0 and an integer multiple of the lateral pixel, because
%     fluence2drm indexes pin cells by round((cx-D/2-xe(1))/h) and needs exact
%     alignment of the cell block with the pixel grid.
if ~isfinite(P.spacing_mm) || P.spacing_mm <= 0
    msgs{end+1} = 'Spot spacing must be > 0 mm; reset to 3 mm.';
    P.spacing_mm = 3.0;
end
ratio = P.spacing_mm / P.lateral_pixel_mm;
if abs(ratio - round(ratio)) > 1e-9
    msgs{end+1} = sprintf(['Spot spacing %.4g mm is not a multiple of the %.4g mm pixel ' ...
                           '(pin cells must align with the grid); reset to 3 mm.'], ...
                          P.spacing_mm, P.lateral_pixel_mm);
    P.spacing_mm = 3.0;
end
D = P.spacing_mm;

% --- widths: > 0, snapped to a whole number of pin cells
[P.widthA_mm, m] = snapWidth(P.widthA_mm, D, 'Region A width', Pprev.widthA_mm);
if ~isempty(m), msgs{end+1} = m; end
[P.widthB_mm, m] = snapWidth(P.widthB_mm, D, 'Region B width', Pprev.widthB_mm);
if ~isempty(m), msgs{end+1} = m; end
[P.fieldX_mm, m] = snapWidth(P.fieldX_mm, D, 'Field x-extent', Pprev.fieldX_mm);
if ~isempty(m), msgs{end+1} = m; end

% --- heights: >= 0, integer multiple of the 1 mm WEPL step
[P.heightA_mm, m] = snapHeight(P.heightA_mm, P.step_wepl_mm, 'Region A height', Pprev.heightA_mm);
if ~isempty(m), msgs{end+1} = m; end
[P.heightB_mm, m] = snapHeight(P.heightB_mm, P.step_wepl_mm, 'Region B height', Pprev.heightB_mm);
if ~isempty(m), msgs{end+1} = m; end

% --- both regions empty -> nothing to irradiate
if P.heightA_mm <= 0 && P.heightB_mm <= 0
    msgs{end+1} = 'Both region heights are 0 - there is no modulator and no plan. Calculation disabled.';
    ok = false;
end

% --- energy must be one of the tabulated DDD files
E = tabulatedEnergies();
if ~any(abs(E - P.energy_MeVu) < 1e-9)
    msgs{end+1} = sprintf('Energy %g MeV/u is not tabulated; reset to 240 MeV/u.', P.energy_MeVu);
    P.energy_MeVu = 240.0;
end
end


function [w, msg] = snapWidth(w, D_mm, label, wPrev)
%SNAPWIDTH  Force a width onto a whole number of pin cells of size D_mm.
%   DEFECT-2 (DEFECTS.md -- FIXED): bad input (non-finite or <= 0) RESTORES
%   the previous value wPrev, matching PLAN.md T28 ("Rejected, previous value
%   restored"), instead of clamping to the floor D_mm.  Clamping silently
%   collapsed the region to one pin cell on a typo.
msg = '';
w0  = w;
if ~isfinite(w) || w <= 0
    msg = sprintf('%s must be > 0 mm; kept the previous value %.4g mm.', label, wPrev);
    w   = wPrev;
    return;
end
n = max(1, round(w / D_mm));
w = n * D_mm;
if abs(w - w0) > 1e-9
    msg = sprintf('%s snapped %.4g -> %.4g mm (%d column(s) of %.4g mm).', ...
                  label, w0, w, n, D_mm);
end
end


function [h, msg] = snapHeight(h, step_mm, label, hPrev)
%SNAPHEIGHT  Force a thickness onto a whole number of 1 mm WEPL steps (>= 0).
%   DEFECT-2 (DEFECTS.md -- FIXED): bad input (non-finite or < 0) RESTORES
%   the previous value hPrev, matching PLAN.md T28, instead of clamping to 0
%   -- the old behaviour let a typo (e.g. "-5") silently DELETE a whole region.
msg = '';
h0  = h;
if ~isfinite(h) || h < 0
    msg = sprintf('%s must be >= 0 mm WEPL; kept the previous value %.4g mm.', label, hPrev);
    h   = hPrev;
    return;
end
n = round(h / step_mm);
h = n * step_mm;
if abs(h - h0) > 1e-9
    msg = sprintf('%s snapped %.4g -> %.4g mm WEPL (%d step(s)).', label, h0, h, n);
end
end


function E = tabulatedEnergies()
%TABULATEDENERGIES  The 9 carbon DDD energies available in 200-280 MeV/u.
E = 200:10:280;
end


function C = derivedCounts(P)
%DERIVEDCOUNTS  Map the mm GUI inputs onto the integer counts Python uses.
%   PLAN.md section 3.  All inputs are already snapped by validateParams.
D = P.spacing_mm;
C.D_mm         = D;
C.n_cols_zoneA = max(0, round(P.widthA_mm / D));
C.n_cols_zoneB = max(0, round(P.widthB_mm / D));
C.n_rows_x     = max(1, round(P.fieldX_mm / D));
C.K_A          = round(P.heightA_mm / P.step_wepl_mm);   % levels of a Region A pin
C.K_B          = round(P.heightB_mm / P.step_wepl_mm);   % levels of a Region B pin
C.K            = max(C.K_A, C.K_B);                      % global level count
end


%% ============================================================ PHYSICS (physics.py)

function v = FWHM2SIG()
%FWHM2SIG  sigma = FWHM * FWHM2SIG.
v = 1.0 / (2.0 * sqrt(2.0 * log(2.0)));
end

function v = M_U(),       v = 931.494;          end   % MeV
function v = ME_C2_EV(),  v = 0.51099895e6;     end   % eV
function v = MEVG_TO_GY(),v = 1.602176634e-10;  end   % 1 MeV/g -> Gy


function m = materialData(name)
%MATERIALDATA  Z/A, mean excitation energy I [eV], radiation length X0 [g/cm^2], rho.
switch lower(name)
    case 'water', m = struct('ZA', 10.0/18.0153,  'I_eV', 75.0, 'X0_gcm2', 36.08, 'rho', 1.0);
    case 'pmma',  m = struct('ZA', 54.0/100.117,  'I_eV', 74.0, 'X0_gcm2', 40.55, 'rho', 1.162);
    case 'air',   m = struct('ZA', 0.49919,       'I_eV', 85.7, 'X0_gcm2', 36.62, 'rho', 1.20479e-3);
    otherwise,    error('drm2d:material', 'Unknown material "%s".', name);
end
end


function p = ndtrStd(x)
%NDTRSTD  Standard normal CDF; the identity scipy.special.ndtr uses.
p = 0.5 * erfc(-x / sqrt(2));
end


function y = interpClamp(xt, yt, xq, leftVal, rightVal)
%INTERPCLAMP  np.interp with explicit left/right fill values.
y = interp1(xt, yt, xq, 'linear', NaN);
y(xq < xt(1))   = leftVal;
y(xq > xt(end)) = rightVal;
end


function ddd = readDDD(path_ddd)
%READDDD  TRiP98 depth-dose file.  Cached by path (persistent).
%   Columns: z [cm], dE/dz [MeV cm^2/g per ion], FWHM1 [mm], factor, FWHM2 [mm].
persistent CACHE
if isempty(CACHE), CACHE = containers.Map(); end
if CACHE.isKey(path_ddd), ddd = CACHE(path_ddd); return; end

if exist(path_ddd, 'file') ~= 2
    error('drm2d:noDDD', 'DDD file not found: %s', path_ddd);
end
fid = fopen(path_ddd, 'r');
c = onCleanup(@() fclose(fid));
energy = NaN; rows = []; inData = false;
while true
    line = fgetl(fid);
    if ~ischar(line), break; end
    s = strtrim(line);
    if startsWith(s, '!energy')
        t = strsplit(s);  energy = str2double(t{2});
    elseif startsWith(s, '!ddd')
        inData = true;
    elseif inData && ~isempty(s) && ~startsWith(s, '#') && ~startsWith(s, '!')
        v = str2double(strsplit(s));
        v = v(1:min(5, numel(v)));
        v(end+1:5) = 0;                 %#ok<AGROW>  pad missing columns with 0
        rows(end+1, :) = v;             %#ok<AGROW>
    end
end
[~, o] = sort(rows(:,1));
rows = rows(o, :);
ddd = struct('energy_MeVu', energy, ...
             'z_mm',   rows(:,1) * 10.0, ...   % cm -> mm
             'dedz',   rows(:,2), ...
             'fwhm1',  rows(:,3), ...
             'factor', rows(:,4), ...
             'fwhm2',  rows(:,5));
CACHE(path_ddd) = ddd;
end


function e = dddDosePerIon(ddd, z_mm)
%DDDDOSEPERION  dE/dz [MeV cm^2/g] at water depth z_mm; 0 beyond the table.
e = interpClamp(ddd.z_mm, ddd.dedz, z_mm(:), ddd.dedz(1), 0.0);
e = reshape(e, size(z_mm));
end


function [s1_mm, f, s2_mm] = dddLateral(ddd, z_mm)
%DDDLATERAL  sigma1, halo fraction, sigma2 [mm] of the in-water double Gaussian.
z = z_mm(:);
s1_mm = interpClamp(ddd.z_mm, ddd.fwhm1,  z, ddd.fwhm1(1),  ddd.fwhm1(end))  * FWHM2SIG();
f     = interpClamp(ddd.z_mm, ddd.factor, z, ddd.factor(1), ddd.factor(end));
s2_mm = interpClamp(ddd.z_mm, ddd.fwhm2,  z, ddd.fwhm2(1),  ddd.fwhm2(end))  * FWHM2SIG();
s1_mm = reshape(s1_mm, size(z_mm));
f     = reshape(f,     size(z_mm));
s2_mm = reshape(s2_mm, size(z_mm));
end


function z_mm = dddPeakDepth(ddd)
%DDDPEAKDEPTH  Depth of the Bragg peak in the table [mm].
[~, i] = max(ddd.dedz);
z_mm = ddd.z_mm(i);
end


function rng = readDedx(path_dedx, projectile)
%READDEDX  TRiP98 dE/dx table -> CSDA range-energy relation of 12C in water.
%   Cached by path+projectile.
persistent CACHE
if isempty(CACHE), CACHE = containers.Map(); end
key = [path_dedx '|' projectile];
if CACHE.isKey(key), rng = CACHE(key); return; end

if exist(path_dedx, 'file') ~= 2
    error('drm2d:noDedx', 'dE/dx file not found: %s', path_dedx);
end
fid = fopen(path_dedx, 'r');
c = onCleanup(@() fclose(fid));
E = []; S = []; R = []; active = false; inData = false;
while true
    line = fgetl(fid);
    if ~ischar(line), break; end
    s = strtrim(line);
    if startsWith(s, '!projectile')
        t = strsplit(s);
        active = strcmp(t{2}, projectile);
        inData = false;
        continue;
    end
    if active && startsWith(s, '!dedx')
        inData = true;
        continue;
    end
    if active && inData
        if isempty(s) || startsWith(s, '!') || startsWith(s, '#')
            if startsWith(s, '!'), active = false; end
            continue;
        end
        v = str2double(strsplit(s));
        E(end+1,1) = v(1);  S(end+1,1) = v(2);  R(end+1,1) = v(3);  %#ok<AGROW>
    end
end
rng = struct('E_MeVu', E, 'S', S, 'R_mm', R * 10.0);   % cm -> mm water
CACHE(key) = rng;
end


function R_mm = rangeFromEnergy(rng, E_MeVu)
%RANGEFROMENERGY  CSDA range [mm water]; linear interpolation in log-log.
R_mm = exp(interp1(log(rng.E_MeVu), log(rng.R_mm), log(E_MeVu), 'linear'));
end


function E_MeVu = energyFromRange(rng, R_mm)
%ENERGYFROMRANGE  Inverse of rangeFromEnergy; clamped at the table start.
R_mm = max(R_mm, rng.R_mm(1) * 1.0001);
E_MeVu = exp(interp1(log(rng.R_mm), log(rng.E_MeVu), log(R_mm), 'linear'));
end


function s = betheMassStopping(E_MeVu, mat, I_override_eV)
%BETHEMASSSTOPPING  Relative Bethe mass stopping power (no shell/density terms).
m = materialData(mat);
if nargin < 3 || isempty(I_override_eV), I_eV = m.I_eV; else, I_eV = I_override_eV; end
g  = 1.0 + E_MeVu / M_U();
b2 = 1.0 - 1.0 / g^2;
s  = m.ZA / b2 * (log(2.0 * ME_C2_EV() * b2 * g^2 / I_eV) - b2);
end


function r = mspRatio(mat, E_MeVu, I_water_eV)
%MSPRATIO  (S/rho)_mat / (S/rho)_water at energy E.
r = betheMassStopping(E_MeVu, mat) / betheMassStopping(E_MeVu, 'water', I_water_eV);
end


function [sig_rad, E_out_MeVu] = highlandSigmaTheta(E0_MeVu, massThick_gcm2, mat, ...
                                                    weplPerMass, rng, X0_gcm2)
%HIGHLANDSIGMATHETA  Angular sigma [rad] after a slab, TRiP98 trprst.c style.
%   0.1 g/cm^2 slices, energy of each slice from the residual water range,
%   quadratic sum, log correction on the total thickness.
A = 12; Z = 6; slice_gcm2 = 0.1;
if massThick_gcm2 <= 0
    sig_rad = 0.0;  E_out_MeVu = E0_MeVu;  return;
end
if nargin < 6 || isempty(X0_gcm2)
    X0_gcm2 = materialData(mat).X0_gcm2;
end
R0_mm = rangeFromEnergy(rng, E0_MeVu);
n  = ceil(massThick_gcm2 / slice_gcm2);
dx = massThick_gcm2 / n;
s2 = 0.0;
for i = 1:n
    R_mm = R0_mm - (i - 0.5) * dx * weplPerMass * 10.0;   % residual range [mm water]
    E    = energyFromRange(rng, R_mm);
    g    = 1.0 + E / M_U();
    beta = sqrt(1.0 - 1.0 / g^2);
    p    = A * sqrt(E * E + 2.0 * E * M_U());             % MeV/c, whole ion
    s2   = s2 + (14.1 / (beta * p) * Z * sqrt(dx / X0_gcm2))^2;
end
corr       = 1.0 + log10(massThick_gcm2 / X0_gcm2) / 9.0;
E_out_MeVu = energyFromRange(rng, R0_mm - massThick_gcm2 * weplPerMass * 10.0);
sig_rad    = sqrt(s2) * corr;
end


function L = slabLever2(t_mm, d_exit_mm)
%SLABLEVER2  Fermi-Eyges lateral variance factor: sigma_x^2 = sigma_theta^2 * L.
L = d_exit_mm.^2 + d_exit_mm .* t_mm + t_mm.^2 / 3.0;
end


%% =========================================================== GEOMETRY (geometry.py)

function spots = makeSpots(P)
%MAKESPOTS  Spot centres [mm] and their zone label.  Ports geometry.make_spots.
C  = derivedCounts(P);
D  = C.D_mm;
nx = C.n_rows_x;
ny = C.n_cols_zoneA + C.n_cols_zoneB;
xc = ((0:nx-1) - (nx - 1) / 2.0) * D;
yc = -C.n_cols_zoneA * D + D / 2.0 + (0:ny-1) * D;
[IX, IY] = ndgrid(1:nx, 1:ny);
X = xc(IX);  Y = yc(IY);
spots = struct('x_mm', X(:), 'y_mm', Y(:), ...
               'ix', IX(:), 'iy', IY(:), ...
               'x_centers_mm', xc(:), 'y_centers_mm', yc(:));
spots.isZoneA = spots.y_mm < 0;
end


function w = levelWeplNominal(P)
%LEVELWEPLNOMINAL  Nominal WEPL [mm] of global levels 0..K (index 1 = level 0).
C = derivedCounts(P);
k = (0:C.K)';
if P.level_offset_match
    w = k * P.step_wepl_mm;
else
    w = max(k - 1, 0) * P.step_wepl_mm;
end
w(1) = 0.0;
end


function N = rashiWeights(P, spots)
%RASHIWEIGHTS  N(spot, k) ions in RaShi level k.  Column 1 = level 0.
C = derivedCounts(P);
ns = numel(spots.x_mm);
N  = zeros(ns, C.K + 1);
for i = 1:ns
    if spots.isZoneA(i), hi = C.K_A; else, hi = C.K_B; end
    if hi >= 1
        N(i, 2:hi+1) = P.n_per_spot_layer;    % levels 1..hi
    end
end
end


function [GS, nExp] = gaussKernel(P)
%GAUSSKERNEL  TRiP2stl.m expansion kernel and its ring count.
D = P.spacing_mm;  sig = P.expand_sigma_mm;
GS = [];  nExp = 2;
for ii = 2:10
    g = (-ii:ii) * D;
    [XX, YY] = meshgrid(g, g);
    GS = exp(-(XX.^2 + YY.^2) / (2 * sig^2)) / (2 * pi * sig^2) * D^2;
    s  = sum(GS(:));
    nExp = ii;
    if 1 - s < P.expand_size_thresh
        GS = GS / s;
        return;
    end
end
GS = GS / sum(GS(:));
end


function col = zoneProfile(P, isZoneA, K)
%ZONEPROFILE  Level weights of an in-field pin of one zone, index 1..K = levels 1..K.
C = derivedCounts(P);
col = zeros(K, 1);
if isZoneA, hi = C.K_A; else, hi = C.K_B; end
if hi >= 1
    col(1:hi) = P.n_per_spot_layer;
end
end


function [pins, info] = buildPins(P, spots)
%BUILDPINS  Stair-pin geometry.  Ports geometry.build_pins (both expand modes).
%   pins is a struct array with fields cx_mm, cy_mm, original, levels (global
%   indices 1..K), weights (sum 1), halfWidths_mm.
C  = derivedCounts(P);
D  = C.D_mm;  K = C.K;
NX = numel(spots.x_centers_mm);
NY = numel(spots.y_centers_mm);
N  = rashiWeights(P, spots);

W3 = zeros(NX, NY, K);                       % level 1..K -> index 1..K
for i = 1:numel(spots.x_mm)
    W3(spots.ix(i), spots.iy(i), :) = N(i, 2:end);
end

xc = spots.x_centers_mm(:);
yc = spots.y_centers_mm(:);
orig = true(NX, NY);
nExp = 0;

if P.gauss_expand && K > 0
    if ~any(strcmpi(P.expand_mode, {'gauss', 'replicate'}))
        error('drm2d:expandMode', 'Unknown expand_mode "%s".', P.expand_mode);
    end
    [GS, nExp] = gaussKernel(P);
    W3   = padarray3(W3, nExp);
    orig = padarray2(orig, nExp, false);
    conv = zeros(size(W3));
    for k = 1:K
        conv(:,:,k) = conv2(W3(:,:,k), GS, 'same');
    end
    xc = [xc(1) - D*(nExp:-1:1)'; xc; xc(end) + D*(1:nExp)'];
    yc = [yc(1) - D*(nExp:-1:1)'; yc; yc(end) + D*(1:nExp)'];

    if strcmpi(P.expand_mode, 'replicate')
        % Outside pins are exact copies of the in-field pin of the same zone;
        % the zone is taken from the pin's own y coordinate.
        colA = zoneProfile(P, true,  K);
        colB = zoneProfile(P, false, K);
        for a = 1:size(W3,1)
            for b = 1:size(W3,2)
                if orig(a,b)
                    conv(a,b,:) = W3(a,b,:);
                elseif yc(b) < 0
                    conv(a,b,:) = colA;
                else
                    conv(a,b,:) = colB;
                end
            end
        end
    else
        % gauss: keep the original pins, then trim low relative weights of the
        % new pins from both ends (bottom-up and top-down), as TRiP2stl does.
        for a = 1:size(W3,1)
            for b = 1:size(W3,2)
                if orig(a,b)
                    conv(a,b,:) = W3(a,b,:);
                    continue;
                end
                col = squeeze(conv(a,b,:));
                small = col < P.expand_min_rel_weight * sum(col);
                for k = 1:K
                    if small(k), col(k) = 0.0; else, break; end
                end
                for k = K:-1:1
                    if small(k), col(k) = 0.0; else, break; end
                end
                conv(a,b,:) = col;
            end
        end
    end
    W3 = conv;
end

pins = struct('cx_mm', {}, 'cy_mm', {}, 'original', {}, ...
              'levels', {}, 'weights', {}, 'halfWidths_mm', {});
for a = 1:size(W3,1)
    for b = 1:size(W3,2)
        col = squeeze(W3(a,b,:));
        nz  = find(col > 0);
        if isempty(nz), continue; end
        w   = col(nz) / sum(col(nz));
        cum = flipud(cumsum(flipud(w)));            % sum_{j>=m} w_j
        hw  = sqrt(cum) * D / 2.0;                  % square pins: side ~ sqrt(area fraction)
        pins(end+1) = struct('cx_mm', xc(a), 'cy_mm', yc(b), ...
                             'original', orig(a,b), 'levels', nz(:), ...
                             'weights', w(:), 'halfWidths_mm', hw(:));  %#ok<AGROW>
    end
end

info = struct('n_expand', nExp, 'n_pins', numel(pins), 'n_original', sum(orig(:)), ...
              'pinned_x_mm', [xc(1) - D/2, xc(end) + D/2], ...
              'pinned_y_mm', [yc(1) - D/2, yc(end) + D/2]);
end


function B = padarray3(A, n)
%PADARRAY3  Zero-pad the first two dimensions of a 3-D array by n on each side.
[nx, ny, nz] = size(A);
B = zeros(nx + 2*n, ny + 2*n, nz);
B(n+1:n+nx, n+1:n+ny, :) = A;
end


function B = padarray2(A, n, val)
%PADARRAY2  Pad a 2-D array by n on each side with val.
[nx, ny] = size(A);
B = repmat(val, nx + 2*n, ny + 2*n);
B(n+1:n+nx, n+1:n+ny) = A;
end


function T = thicknessMap(pins, levelWepl_mm, x_mm, y_mm, D_mm)
%THICKNESSMAP  Nominal WEPL thickness [mm] at points (x,y) -> T(ix, iy).
[X, Y] = ndgrid(x_mm(:), y_mm(:));
T = zeros(size(X));
for p = 1:numel(pins)
    pin = pins(p);
    dx = abs(X - pin.cx_mm);  dy = abs(Y - pin.cy_mm);
    inside = (dx <= D_mm/2) & (dy <= D_mm/2);
    if ~any(inside(:)), continue; end
    r = max(dx, dy);                                   % square (Chebyshev) radius
    for m = 1:numel(pin.levels)
        sel = inside & (r <= pin.halfWidths_mm(m));
        T(sel) = levelWepl_mm(pin.levels(m) + 1);      % +1: index 1 = level 0
    end
end
end


%% ============================================================ FLUENCE (fluence.py)

function grid = makeGrid(halfX_mm, halfY_mm, h_mm)
%MAKEGRID  Pixel edges; half-widths are rounded up so 1 mm voxels align.
hx = ceil(halfX_mm);  hy = ceil(halfY_mm);
nx = round(2*hx / h_mm);  ny = round(2*hy / h_mm);
grid = struct('h_mm', h_mm, ...
              'xe_mm', (-hx + (0:nx) * h_mm)', ...
              'ye_mm', (-hy + (0:ny) * h_mm)');
grid.xc_mm = 0.5 * (grid.xe_mm(1:end-1) + grid.xe_mm(2:end));
grid.yc_mm = 0.5 * (grid.ye_mm(1:end-1) + grid.ye_mm(2:end));
grid.nx = numel(grid.xc_mm);
grid.ny = numel(grid.yc_mm);
end


function Pm = pixelGauss1d(edges_mm, mu_mm, sig_mm)
%PIXELGAUSS1D  Pm(s,i) = integral of spot s's Gaussian over pixel i.
c  = ndtrStd((edges_mm(:)' - mu_mm(:)) / sig_mm);     % (S, nEdges)
Pm = diff(c, 1, 2);                                   % (S, nPix)
end


function v = segInt(lo, hi, mu, sig)
%SEGINT  Integral of a unit Gaussian N(mu,sig) over [lo,hi]; 0 where hi <= lo.
v = ndtrStd((hi - mu) / sig) - ndtrStd((lo - mu) / sig);
v(hi <= lo) = 0.0;
end


function F = fluenceRashi(grid, spots, N, sigma0_mm)
%FLUENCERASHI  F(nx, ny, K+1): ions per pixel per level, spot-labelled.
%   NOTE index order: Python returns (K+1, nx, ny); MATLAB uses level LAST so the
%   leading two dimensions stay contiguous for the Kx*F*Ky' products in computeDose.
Px = pixelGauss1d(grid.xe_mm, spots.x_mm, sigma0_mm);     % (S, nx)
Py = pixelGauss1d(grid.ye_mm, spots.y_mm, sigma0_mm);     % (S, ny)
K1 = size(N, 2);
F  = zeros(grid.nx, grid.ny, K1);
for k = 1:K1
    w = N(:, k);
    s = w ~= 0;
    if ~any(s), continue; end
    F(:,:,k) = Px(s,:)' * (w(s) .* Py(s,:));              % sum_s Px(s,a) N(s,k) Py(s,b)
end
end


function F = fluence2drm(grid, spots, W, sigma0_mm, pins, D_mm, K)
%FLUENCE2DRM  F(nx, ny, K+1): ions per pixel per level, position-labelled.
%   F(:,:,1) = level 0 = ions that miss the modulator.
Px = pixelGauss1d(grid.xe_mm, spots.x_mm, sigma0_mm);     % (S, nx)
Py = pixelGauss1d(grid.ye_mm, spots.y_mm, sigma0_mm);     % (S, ny)
F_all = Px' * (W(:) .* Py);                               % (nx, ny) total ions per pixel

F = zeros(grid.nx, grid.ny, K + 1);
h = grid.h_mm;
np = round(D_mm / h);                                     % pixels per pin cell
for p = 1:numel(pins)
    pin = pins(p);
    i0 = round((pin.cx_mm - D_mm/2 - grid.xe_mm(1)) / h);   % 0-based block start
    j0 = round((pin.cy_mm - D_mm/2 - grid.ye_mm(1)) / h);
    ii = i0 + (1:np);   jj = j0 + (1:np);                   % 1-based pixel indices
    if ii(1) < 1 || ii(end) > grid.nx || jj(1) < 1 || jj(end) > grid.ny
        continue;                                           % cell outside the grid
    end
    xlo = grid.xe_mm(ii);      xhi = grid.xe_mm(ii + 1);
    ylo = grid.ye_mm(jj);      yhi = grid.ye_mm(jj + 1);
    hw  = [pin.halfWidths_mm(:); 0.0];                      % (m+1,) descending to 0
    m1  = numel(hw);

    % Overlap of each pixel with the square of half-width hw(m): (m+1, nPix)
    axlo = max(repmat(xlo(:)', m1, 1), pin.cx_mm - hw);
    axhi = min(repmat(xhi(:)', m1, 1), pin.cx_mm + hw);
    aylo = max(repmat(ylo(:)', m1, 1), pin.cy_mm - hw);
    ayhi = min(repmat(yhi(:)', m1, 1), pin.cy_mm + hw);

    % Ix(m, s, a), Iy(m, s, b)
    S = numel(spots.x_mm);
    Ix = zeros(m1, S, np);  Iy = zeros(m1, S, np);
    for m = 1:m1
        Ix(m,:,:) = segInt(repmat(axlo(m,:), S, 1), repmat(axhi(m,:), S, 1), spots.x_mm, sigma0_mm);
        Iy(m,:,:) = segInt(repmat(aylo(m,:), S, 1), repmat(ayhi(m,:), S, 1), spots.y_mm, sigma0_mm);
    end
    % A(m, a, b) = sum_s Ix(m,s,a) W(s) Iy(m,s,b): ions inside square m
    A = zeros(m1, np, np);
    for m = 1:m1
        Xm = squeeze(Ix(m,:,:));  Ym = squeeze(Iy(m,:,:));   % (S, np)
        if S == 1, Xm = Xm(:)'; Ym = Ym(:)'; end
        A(m,:,:) = Xm' * (W(:) .* Ym);
    end
    R = A(1:end-1,:,:) - A(2:end,:,:);                       % ions in annulus m
    for m = 1:numel(pin.levels)
        k = pin.levels(m) + 1;                               % +1: index 1 = level 0
        F(ii, jj, k) = F(ii, jj, k) + squeeze(R(m,:,:));
    end
end
F(:,:,1) = F_all - sum(F(:,:,2:end), 3);
tiny = abs(F(:,:,1)) < 1e-9 * max(F_all(:));
Fz = F(:,:,1);  Fz(tiny) = 0.0;  F(:,:,1) = Fz;
end


%% ================================================================ DOSE (dose.py)

function wer = pmmaWer(P, E_MeVu)
%PMMAWER  PMMA water-equivalent ratio in the selected mode.
if strcmpi(P.pmma_wer_mode, 'nominal')
    wer = P.height_scale;
else
    wer = P.pmma_density * mspRatio('pmma', E_MeVu, P.I_water_eV);
end
end


function lp = levelProps(P, plan, rng)
%LEVELPROPS  Per-level transport properties.  Ports dose.level_props.
%   Fields (all indexed 1..K+1, index 1 = level 0):
%     wepl_mm, tGeom_mm, dExit0_mm, thetaDev_rad, thetaAir_rad, EAfter_MeVu, airWepl_mm
wn = levelWeplNominal(P);
E0 = P.energy_MeVu;

switch lower(plan)
    case 'rashi'
        mat = P.rashi_material;
        md  = materialData(mat);
        rho = md.rho;
        X0  = md.X0_gcm2;
        if strcmpi(mat, 'water')
            t = wn;
            weplPerMass = 1.0;
        else
            weplPerMass = mspRatio(mat, E0, P.I_water_eV);
            t = wn ./ (rho * weplPerMass);
        end
        wepl   = t * rho * weplPerMass;
        dExit0 = repmat(P.gap_mm, size(t));
    case '2drm'
        mat = 'pmma';
        rho = P.pmma_density;
        X0  = P.pmma_X0_gcm2;
        t   = wn / P.height_scale + (wn > 0) * P.base_thickness_mm;
        wer = pmmaWer(P, E0);
        wepl = t * wer;
        weplPerMass = wer / rho;
        if P.pin_tips_upstream
            dExit0 = repmat(P.gap_mm, size(t));
        else
            dExit0 = P.gap_mm + (max(t) - t);
        end
    otherwise
        error('drm2d:plan', 'Unknown plan "%s".', plan);
end

n = numel(t);
thDev = zeros(n,1);  EAfter = repmat(E0, n, 1);  thAir = zeros(n,1);
if strcmpi(P.gap_material, 'air')
    airMass = materialData('air').rho * P.gap_mm / 10.0;    % g/cm^2
else
    airMass = 0.0;
end
airWpm = mspRatio('air', E0, P.I_water_eV);
for k = 1:n
    if t(k) > 0
        [th, Ea] = highlandSigmaTheta(E0, t(k) * rho / 10.0, mat, weplPerMass, rng, X0);
        if P.device_scattering, thDev(k) = th; end
        EAfter(k) = Ea;
    end
    if airMass > 0 && P.air_scattering
        thAir(k) = highlandSigmaTheta(EAfter(k), airMass, 'air', airWpm, rng, []);
    end
end
if P.include_air_wepl
    airWepl = airMass * airWpm * 10.0;
else
    airWepl = 0.0;
end

lp = struct('wepl_mm', wepl(:), 'tGeom_mm', t(:), 'dExit0_mm', dExit0(:), ...
            'thetaDev_rad', thDev, 'thetaAir_rad', thAir, ...
            'EAfter_MeVu', EAfter, 'airWepl_mm', airWepl);
end


function M = blurMatrix(edges_mm, centers_mm, sig_mm)
%BLURMATRIX  M(i,j) = probability that an ion at centre j lands in bin i.
if sig_mm < 1e-6
    M = eye(numel(centers_mm));
    return;
end
c = ndtrStd((edges_mm(:) - centers_mm(:)') / sig_mm);
M = diff(c, 1, 1);
end


function [s1_mm, f, s2_mm] = levelSigma(P, lp, ddd, z_mm, k)
%LEVELSIGMA  Lateral sigmas [mm] of level k (1-based index into lp) at depth z.
w   = lp.wepl_mm(k) + lp.airWepl_mm;
sc2 = lp.thetaDev_rad(k)^2 * slabLever2(lp.tGeom_mm(k), lp.dExit0_mm(k) + z_mm) ...
    + lp.thetaAir_rad(k)^2 * slabLever2(P.gap_mm, z_mm);
if P.phantom_lateral
    [a1, f, a2] = dddLateral(ddd, w + z_mm);
    [b1, ~, b2] = dddLateral(ddd, w);
    w1 = max(a1^2 - b1^2, 0.0);
    w2 = max(a2^2 - b2^2, 0.0);
else
    w1 = 0.0; w2 = 0.0; f = 0.0;
end
s1_mm = sqrt(sc2 + w1);
s2_mm = sqrt(sc2 + w2);
end


function [dose_Gy, zEdges_mm] = computeDose(P, grid, F, lp, ddd, zMax_mm)
%COMPUTEDOSE  Dose [Gy] on voxel_mm depth bins.  Ports dose.compute_dose.
%   F is (nx, ny, K+1).  Returns dose (nz, nx, ny) to match the Python layout.
nx = grid.nx;  ny = grid.ny;  h = grid.h_mm;
K1 = size(F, 3);

% Only levels that actually carry ions
maxPerLevel = zeros(K1,1);
for k = 1:K1, maxPerLevel(k) = max(max(F(:,:,k))); end
active = find(maxPerLevel > 0);
nA = numel(active);

nzv = ceil(zMax_mm / P.voxel_mm);
zEdges_mm = (0:nzv)' * P.voxel_mm;
zNodes = (0:P.dz_node_mm:(zEdges_mm(end) + P.dz_node_mm + 1e-9))';
nf = round(P.voxel_mm / P.dz_fine_mm);

dose_Gy = zeros(nzv, nx, ny);
if nA == 0, return; end

Clo = lateralSpread(P, grid, F, lp, ddd, active, zNodes(1));
for j = 1:numel(zNodes)-1
    z0 = zNodes(j);  z1 = zNodes(j+1);
    vox = find(zEdges_mm(1:end-1) >= z0 - 1e-9 & zEdges_mm(1:end-1) < z1 - 1e-9);
    vox = vox(vox <= nzv);
    if isempty(vox), break; end
    Chi = lateralSpread(P, grid, F, lp, ddd, active, z1);
    for v = vox(:)'
        zf    = zEdges_mm(v) + ((0:nf-1)' + 0.5) * P.dz_fine_mm;
        alpha = (zf - z0) / (z1 - z0);
        a = zeros(nA,1);  b = zeros(nA,1);
        for n = 1:nA
            e = dddDosePerIon(ddd, zf + lp.wepl_mm(active(n)) + lp.airWepl_mm);
            a(n) = mean(e .* (1 - alpha));
            b(n) = mean(e .* alpha);
        end
        acc = zeros(nx, ny);
        for n = 1:nA
            acc = acc + a(n) * Clo(:,:,n) + b(n) * Chi(:,:,n);
        end
        dose_Gy(v,:,:) = acc * MEVG_TO_GY();
    end
    Clo = Chi;
end
end


function C = lateralSpread(P, grid, F, lp, ddd, active, z_mm)
%LATERALSPREAD  C(nx, ny, nActive): ions/cm^2 at depth z for each active level.
nA = numel(active);
C  = zeros(grid.nx, grid.ny, nA);
h  = grid.h_mm;
% The x and y pixel grids are identical whenever the pinned area is square, which
% is the normal case. Then blurMatrix(x) == blurMatrix(y) and one erfc evaluation
% serves both directions -- erfc dominates the runtime, so this roughly halves it.
sameGrid = isequal(grid.xe_mm, grid.ye_mm);
for n = 1:nA
    k = active(n);
    [s1, f, s2] = levelSigma(P, lp, ddd, z_mm, k);
    Kx = blurMatrix(grid.xe_mm, grid.xc_mm, s1);
    if sameGrid, Ky = Kx; else, Ky = blurMatrix(grid.ye_mm, grid.yc_mm, s1); end
    c  = (1 - f) * (Kx * F(:,:,k) * Ky');
    if f > 0
        Kx2 = blurMatrix(grid.xe_mm, grid.xc_mm, s2);
        if sameGrid, Ky2 = Kx2; else, Ky2 = blurMatrix(grid.ye_mm, grid.yc_mm, s2); end
        c   = c + f * (Kx2 * F(:,:,k) * Ky2');
    end
    C(:,:,n) = c / (h * h) * 100.0;        % ions/pixel -> ions/cm^2
end
end


%% ====================================================== NON-LOCALITY (nonlocality.py)

function [KA, KB, K] = zoneLevels(P)
%ZONELEVELS  Level counts of a Region A pin, a Region B pin, and overall.
C = derivedCounts(P);
KA = C.K_A;  KB = C.K_B;  K = C.K;
end


function ne = nExpandRings(P)
%NEXPANDRINGS  Ring count, reproducing the size loop of gaussKernel.
if ~P.gauss_expand
    ne = 0;  return;
end
[~, ne] = gaussKernel(P);
end


function [xe_mm, ye_mm] = cellEdges(P)
%CELLEDGES  Pin-cell edges covering the pinned area.
C  = derivedCounts(P);
D  = C.D_mm;
ne = nExpandRings(P);
nx = C.n_rows_x + 2*ne;
ny = C.n_cols_zoneA + C.n_cols_zoneB + 2*ne;
xe_mm = ((0:nx)' - nx/2.0) * D;
ye_mm = -(C.n_cols_zoneA + ne) * D + (0:ny)' * D;
end


function v = gaussCell(edges_mm, mu_mm, sig_mm)
%GAUSSCELL  Integral of a unit Gaussian over each bin, summed over the mu values.
if isempty(mu_mm)
    v = zeros(numel(edges_mm) - 1, 1);
    return;
end
c = ndtrStd((edges_mm(:)' - mu_mm(:)) / sig_mm);     % (nMu, nEdges)
v = sum(diff(c, 1, 2), 1)';                          % (nBins, 1)
end


function [xe_mm, ye_mm, px, pyA, pyB] = zoneFluenceProfiles(P)
%ZONEFLUENCEPROFILES  Cell-integrated fluence factors, in units of "spots".
%   m_A(c) = px(ix)*pyA(iy),  m_B(c) = px(ix)*pyB(iy)
s   = makeSpots(P);
sig = P.fwhm0_mm * FWHM2SIG();
[xe_mm, ye_mm] = cellEdges(P);
yA  = s.y_centers_mm(s.y_centers_mm < 0);
yB  = s.y_centers_mm(s.y_centers_mm > 0);
px  = gaussCell(xe_mm, s.x_centers_mm, sig);
pyA = gaussCell(ye_mm, yA, sig);
pyB = gaussCell(ye_mm, yB, sig);
end


function [yc_mm, f] = fZoneA(P, y_mm)
%FZONEA  Zone-mixing fraction f_A per cell row -- the ONLY place the FWHM enters.
[~, ye, ~, pyA, pyB] = zoneFluenceProfiles(P);
yc_mm = 0.5 * (ye(1:end-1) + ye(2:end));
tot = pyA + pyB;
f = nan(size(pyA));
f(tot > 0) = pyA(tot > 0) ./ tot(tot > 0);
if nargin >= 2 && ~isempty(y_mm)
    f = interp1(yc_mm, f, y_mm, 'linear', NaN);
    yc_mm = y_mm;
end
end


function a = spectralWeight(P)
%SPECTRALWEIGHT  Two-block spectrum a_k, k = 1..K.  *** D2-CORRECTED FORM ***
%
%   Python nonlocality.spectral_weight() builds k = 1:max(K_A,K_B) and
%   where(k <= K_B, K_A-K_B, -K_B).  When K_B >= K_A the second branch is
%   unreachable, a_k collapses to the constant K_A-K_B and sum(a_k) ~= 0
%   (verified: K_A=30, K_B=50 gives sum = -1000).  This GUI can reach that
%   state, so the general form is used here:
%
%       a_k = dK                  for 1     <= k <= K_lo
%           = -K_lo * sign(dK)    for K_lo  <  k <= K_hi
%
%   sum(a_k) = K_lo*dK + (K_hi-K_lo)*(-K_lo*sign(dK))
%            = K_lo*dK - K_lo*|dK|*sign(dK) = 0  for either ordering.
[KA, KB, K] = zoneLevels(P);
dK   = KA - KB;                 % signed
K_lo = min(KA, KB);
K_hi = max(KA, KB);
k = (1:K)';
a = zeros(K, 1);
a(k <= K_lo) = dK;
a(k > K_lo & k <= K_hi) = -K_lo * sign(dK);
% k > K_hi stays 0 (cannot happen since K = K_hi, kept for clarity)
assert(abs(sum(a)) < 1e-9, 'drm2d:nlConserve', ...
       'spectralWeight: sum(a_k) = %g, expected 0 (K_A=%d, K_B=%d).', sum(a), KA, KB);
end


function [xe_mm, ye_mm, u, px, v] = spatialProfile(P)
%SPATIALPROFILE  u(c) = +m_A/K_B in Region B cells, -m_B/K_A in Region A cells.
%   u is separable: u = px * v'.
[KA, KB, ~] = zoneLevels(P);
[xe_mm, ye_mm, px, pyA, pyB] = zoneFluenceProfiles(P);
yc = 0.5 * (ye_mm(1:end-1) + ye_mm(2:end));
v = zeros(size(yc));
if KB > 0, v(yc > 0) =  pyA(yc > 0) / KB; end
if KA > 0, v(yc < 0) = -pyB(yc < 0) / KA; end
u = px * v';
end


function [dPhi, xe_mm, ye_mm] = deltaPhiLevels(P)
%DELTAPHILEVELS  Closed-form dPhi_k per pin cell [ions]; dPhi(:,:,k) for level k.
%   Sums to zero over k by construction (see spectralWeight).
[xe_mm, ye_mm, u] = spatialProfile(P);
a = spectralWeight(P);
dPhi = zeros([size(u), numel(a)]);
for k = 1:numel(a)
    dPhi(:,:,k) = P.n_per_spot_layer * a(k) * u;
end
end


function out = cellsToPixels(cellVals, cellE_mm, pixE_mm)
%CELLSTOPIXELS  Spread a per-cell quantity uniformly over its pixels (approx. A1).
%   cellVals is (nRows, nCells); out is (nRows, nPix).
if isvector(cellVals), cellVals = cellVals(:)'; end
nRows = size(cellVals, 1);
nC    = size(cellVals, 2);
pc    = 0.5 * (pixE_mm(1:end-1) + pixE_mm(2:end));
% np.searchsorted(cellE, pc, side='left') - 1, i.e. the 0-based cell index
idx0 = sum(cellE_mm(:)' < pc(:), 2) - 1;
ok   = idx0 >= 0 & idx0 < nC;
npix = (cellE_mm(2) - cellE_mm(1)) / (pixE_mm(2) - pixE_mm(1));
out  = zeros(nRows, numel(pc));
out(:, ok) = cellVals(:, idx0(ok) + 1) / npix;
end


function [xe_mm, ye_mm] = pixelGridNL(P, half_mm)
%PIXELGRIDNL  Fine pixel edges of the dose grid (matches makeGrid for the model run).
h = P.lateral_pixel_mm;
n = round(2 * half_mm / h);
xe_mm = (-half_mm + (0:n)' * h);
ye_mm = xe_mm;
end


function [xe_mm, ye_mm, pxPix, vPix] = deltaPhiPixels(P, half_mm)
%DELTAPHIPIXELS  Separable dPhi factors on the fine pixel grid.
%   dPhi_k(pixel) = N0 * a_k * pxPix * vPix'
[xe_mm, ye_mm] = pixelGridNL(P, half_mm);
[xeC, yeC, ~, pxC, vC] = spatialProfile(P);
pxPix = cellsToPixels(pxC', xeC, xe_mm);  pxPix = pxPix(:);
vPix  = cellsToPixels(vC',  yeC, ye_mm);  vPix  = vPix(:);
end


function [dose_Gy, zEdges_mm, xEdges_mm, yEdges_mm] = foldSeparable(P, ddd, jobs, voxel_mm, half_mm)
%FOLDSEPARABLE  Transport separable, level-resolved fluence terms to dose [Gy].
%   Each job: struct('lp',LevelProps, 'x',(npix,1), 'y',(npix,K), 'sign',+-1)
%   describing sign * sum_k x * y(:,k)' ions per pixel on level k.
[xe, ye] = pixelGridNL(P, half_mm);
xc = 0.5*(xe(1:end-1) + xe(2:end));
yc = 0.5*(ye(1:end-1) + ye(2:end));
h  = P.lateral_pixel_mm;
K  = size(jobs(1).y, 2);

if P.z_max_mm > 0, zMax = P.z_max_mm; else, zMax = ceil(dddPeakDepth(ddd) + 30.0); end
nzv = ceil(zMax / voxel_mm);
zEdges_mm = (0:nzv)' * voxel_mm;
zNodes = (0:P.dz_node_mm:(zEdges_mm(end) + P.dz_node_mm + 1e-9))';
nf = round(voxel_mm / P.dz_fine_mm);

unit = P.n_per_spot_layer / (h*h) * 100.0 * MEVG_TO_GY();   % ions/pixel -> Gy
dose_Gy = zeros(nzv, numel(xc), numel(yc));

lo = foldFactors(P, ddd, jobs, xe, xc, ye, yc, K, zNodes(1));
for j = 1:numel(zNodes)-1
    z0 = zNodes(j);  z1 = zNodes(j+1);
    vox = find(zEdges_mm(1:end-1) >= z0 - 1e-9 & zEdges_mm(1:end-1) < z1 - 1e-9);
    vox = vox(vox <= nzv);
    if isempty(vox), break; end
    hi = foldFactors(P, ddd, jobs, xe, xc, ye, yc, K, z1);
    for vx = vox(:)'
        zf    = zEdges_mm(vx) + ((0:nf-1)' + 0.5) * P.dz_fine_mm;
        alpha = (zf - z0) / (z1 - z0);
        acc = zeros(numel(xc), numel(yc));
        for n = 1:numel(jobs)
            lp = jobs(n).lp;
            wlo = zeros(K,1);  whi = zeros(K,1);
            for k = 1:K
                e = dddDosePerIon(ddd, zf + lp.wepl_mm(k+1) + lp.airWepl_mm);
                wlo(k) = jobs(n).sign * mean(e .* (1 - alpha));
                whi(k) = jobs(n).sign * mean(e .* alpha);
            end
            % sum_k w_k * X(:,k) * Y(:,k)'  ==  X * diag(w) * Y'
            % (Python: L[0].T @ (wlo[:,None] * L[1]), with Python X1 = our X1.')
            L = lo(n);  H = hi(n);
            acc = acc + L.X1 * (wlo .* L.Y1.') ...
                      + L.X2 * (wlo .* L.Y2.') ...
                      + H.X1 * (whi .* H.Y1.') ...
                      + H.X2 * (whi .* H.Y2.');
        end
        dose_Gy(vx,:,:) = acc;
    end
    lo = hi;
end
dose_Gy = dose_Gy * unit;

% average the fine pixels up to the output voxel size
f = round(voxel_mm / h);
if f > 1
    nx = size(dose_Gy, 2);  ny = size(dose_Gy, 3);
    dose_Gy   = blockMean3(dose_Gy, f);
    xEdges_mm = xe(1:f:end);  xEdges_mm = xEdges_mm(1:floor(nx/f) + 1);
    yEdges_mm = ye(1:f:end);  yEdges_mm = yEdges_mm(1:floor(ny/f) + 1);
else
    xEdges_mm = xe;  yEdges_mm = ye;
end
end


function out = blockMean3(d, f)
%BLOCKMEAN3  Average f x f blocks of the last two dimensions of (nz, nx, ny).
%   Matches numpy reshape(nz, nx/f, f, ny/f, f).mean(axis=(2,4)).
[nz, nx, ny] = size(d);
nx2 = nx - mod(nx, f);  ny2 = ny - mod(ny, f);
d = d(:, 1:nx2, 1:ny2);
d = reshape(d, nz, f, nx2/f, ny2);        % x fastest -> (nz, f, nx/f, ny)
d = squeeze(mean(d, 2));                  % (nz, nx/f, ny)
d = reshape(d, nz, nx2/f, f, ny2/f);      % y fastest
out = squeeze(mean(d, 3));                % (nz, nx/f, ny/f)
if nz == 1, out = reshape(out, 1, nx2/f, ny2/f); end
end


function [d, xe_v, ye_v] = toVoxels(dose, grid, voxel_mm)
%TOVOXELS  Average lateral PIXELS into voxel_mm voxels.  Ports analysis.to_voxels
%   (analytic_model/analysis.py:16-21).  dose (nz,nx,ny) on the pixel grid ->
%   (nz,nx/f,ny/f) on the voxel grid; f = round(voxel_mm/h).
%
%   PLAN3.md section 5: this is a MISSING FEATURE, not a defect fix.  Python
%   block-averages every dose to 1 mm voxels before any figure, CSV or npz;
%   this port never did, so rashi_Gy/local_Gy/exact_Gy stayed on the
%   lateral_pixel_mm grid while nl_Gy (foldSeparable, which already does this
%   averaging) arrived on the voxel grid -- a factor-of-2 mismatch at the
%   reference 0.5 mm pixel that matchGrid "fixed" by zero-padding into a
%   corner (DEFECT-3/DEFECT-4, left unfixed per PLAN3 section 2.0 -- see the
%   comment at matchGrid below).  Calling toVoxels on every stored dose closes
%   that gap directly, which is why it is "mandatory" rather than optional.
%
%   f == 1 (coarse mode, h == voxel_mm) is an EARLY RETURN -- the identity,
%   bitwise, not a mean-of-one -- so every check that only ever runs at the
%   coarse 1.0 mm default (the whole fast selftest) is untouched by this
%   function's existence.
f = round(voxel_mm / grid.h_mm);
if f <= 1
    d = dose;  xe_v = grid.xe_mm;  ye_v = grid.ye_mm;
    return;
end
[~, nx, ny] = size(dose);
d    = blockMean3(dose, f);
xe_v = grid.xe_mm(1:f:end);  xe_v = xe_v(1:floor(nx/f) + 1);
ye_v = grid.ye_mm(1:f:end);  ye_v = ye_v(1:floor(ny/f) + 1);
end


function [d, xec, yec] = cellAverage(D, xe, ye, period)
%CELLAVERAGE  Average 1 mm voxels over pin cells (period x period mm, aligned
%   with the pin grid).  Ports analysis.cell_average (PLAN3.md section 3, P3).
%   MUST include the i0/j0 edge-alignment search below -- blockMean3 starts at
%   index 1 and bins on the wrong 3 mm phase, so it is NOT a substitute here.
h  = xe(2) - xe(1);
f  = round(period / h);
[~, i0] = min(abs(mod(xe + period/2, period) - period/2));   % MATLAB 1-based
[~, j0] = min(abs(mod(ye + period/2, period) - period/2));
i0 = i0 - 1;   % convert to the 0-based index Python's i0 is
j0 = j0 - 1;
nx = floor((numel(xe) - 1 - i0) / f);
ny = floor((numel(ye) - 1 - j0) / f);
sub = D(:, i0+1 : i0+nx*f, j0+1 : j0+ny*f);
nz  = size(sub, 1);
sub = reshape(sub, nz, f, nx, ny*f);      % x: f fastest within each cell
sub = squeeze(mean(sub, 2));              % (nz, nx, ny*f)
if nz == 1, sub = reshape(sub, 1, nx, ny*f); end
sub = reshape(sub, nz, nx, f, ny);        % y: f fastest within each cell
d   = squeeze(mean(sub, 3));              % (nz, nx, ny)
if nz == 1, d = reshape(d, 1, nx, ny); end
xec = xe(i0+1 : f : i0+nx*f+1);
yec = ye(j0+1 : f : j0+ny*f+1);
end


function out = foldFactors(P, ddd, jobs, xe, xc, ye, yc, K, z_mm)
%FOLDFACTORS  Per job: rank-2 separable lateral factors for every level at depth z.
out = struct('X1', {}, 'Y1', {}, 'X2', {}, 'Y2', {});
sameGrid = isequal(xe, ye);        % reuse one erfc evaluation for both directions
for n = 1:numel(jobs)
    jb = jobs(n);
    X1 = zeros(numel(xc), K);  Y1 = zeros(numel(yc), K);
    X2 = zeros(numel(xc), K);  Y2 = zeros(numel(yc), K);
    for k = 1:K
        [s1, f, s2] = levelSigma(P, jb.lp, ddd, z_mm, k + 1);   % +1: index 1 = level 0
        M1 = blurMatrix(xe, xc, s1);
        X1(:,k) = M1 * jb.x;
        if sameGrid, N1 = M1; else, N1 = blurMatrix(ye, yc, s1); end
        Y1(:,k) = (1.0 - f) * (N1 * jb.y(:,k));
        if f > 0
            M2 = blurMatrix(xe, xc, s2);
            X2(:,k) = M2 * jb.x;
            if sameGrid, N2 = M2; else, N2 = blurMatrix(ye, yc, s2); end
            Y2(:,k) = f * (N2 * jb.y(:,k));
        end
    end
    out(n) = struct('X1', X1, 'Y1', Y1, 'X2', X2, 'Y2', Y2);
end
end


function [dose_Gy, zEdges_mm, xEdges_mm, yEdges_mm] = predictDeltaDose(P, ddd, rng, voxel_mm, half_mm)
%PREDICTDELTADOSE  The NON-LOCALITY term of D_2DRM - D_RaShi [Gy].
%   sum_k dPhi_k transported with the RaShi level kernel (approximation A4).
lp = levelProps(P, 'rashi', rng);
a  = spectralWeight(P);
[~, ~, px, v] = deltaPhiPixels(P, half_mm);
y = v * a';                                     % (npix, K): a_k * v(y)
job = struct('lp', lp, 'x', px, 'y', y, 'sign', 1.0);
[dose_Gy, zEdges_mm, xEdges_mm, yEdges_mm] = foldSeparable(P, ddd, job, voxel_mm, half_mm);
end


function [xe_mm, ye_mm, pxPix, qPix] = phi2drmPixels(P, half_mm)
%PHI2DRMPIXELS  Separable cell-averaged 2DRM level fluence on the fine pixel
%   grid.  Ports nonlocality.phi_2drm_pixels (PLAN3.md section 3, P3).
%     Phi_M,k(pixel) = N0 * outer(pxPix, qPix(:,k))
%     q_k(y) = (K_A*pyA + K_B*pyB) / K(y) * 1(k <= K(y))
%   Separable per level because K(y) depends on y only.
[KA, KB, K] = zoneLevels(P);
[xe_mm, ye_mm] = pixelGridNL(P, half_mm);
[xeC, yeC, pxC, pyA, pyB] = zoneFluenceProfiles(P);
yc   = 0.5 * (yeC(1:end-1) + yeC(2:end));
Kc   = KA * ones(size(yc));  Kc(yc > 0) = KB;
base = (KA * pyA + KB * pyB) ./ Kc;              % (nCellsY, 1)
k    = (1:K)';
q    = base' .* (k <= Kc');                      % (K, nCellsY)
pxPix = cellsToPixels(pxC', xeC, xe_mm);  pxPix = pxPix(:);
qPix  = cellsToPixels(q,    yeC, ye_mm).';        % (npix, K)
end


function [dose_Gy, zEdges_mm, xEdges_mm, yEdges_mm] = predictMaterialTerm(P, ddd, rng, voxel_mm, half_mm)
%PREDICTMATERIALTERM  MATERIAL/MCS term: sum_k Phi_M,k (x) (L^M_k e^M_k - L^R_k e^R_k).
%   Ports nonlocality.predict_material_term (PLAN3.md section 3, P3).  This is
%   the PMMA-vs-water difference at FIXED (position-labelled) fluence -- it is
%   what remains in the zone cores, where the non-locality term vanishes, and
%   it is NOT part of the non-locality model.  Two jobs, same (px,q): the
%   2DRM transport with sign +1 and the RaShi transport with sign -1.
[~, ~, px, q] = phi2drmPixels(P, half_mm);
job2drm  = struct('lp', levelProps(P, '2drm',  rng), 'x', px, 'y', q, 'sign',  1.0);
jobRashi = struct('lp', levelProps(P, 'rashi', rng), 'x', px, 'y', q, 'sign', -1.0);
jobs     = [job2drm, jobRashi];
[dose_Gy, zEdges_mm, xEdges_mm, yEdges_mm] = foldSeparable(P, ddd, jobs, voxel_mm, half_mm);
end


%% ================================================================ GUI

function fig = buildGui(P, vis)
%BUILDGUI  Legacy figure + uicontrol (NOT uifigure: must work under matlab -batch).
W = 1340; H = 1100;    % PLAN3.md section 6.4: +220 px for the figure-selection listbox and btn_savefigs
fig = figure('Name', '2DRM Non-locality Demonstrator', 'NumberTitle', 'off', ...
             'Visible', vis, 'Position', [40 40 W H], 'Color', [0.94 0.94 0.94], ...
             'MenuBar', 'none', 'ToolBar', 'figure', 'Tag', 'drm2d_fig');

S = struct();
S.P            = P;
S.energies_MeVu= tabulatedEnergies();
S.expandModes  = {'gauss', 'replicate'};
S.dose         = emptyDose();
S.applyCount   = 0;
S.h            = struct();

panelW = 250;
x0 = 10;

% ---------------- input panels ----------------
yTop = H - 20;
[S.h, yTop] = addPanelBeam(S.h, fig, x0, yTop, panelW, P, S.energies_MeVu);
[S.h, yTop] = addPanelRegion(S.h, fig, x0, yTop, panelW, 'Region A  (y < 0)', ...
                             'edt_wA', P.widthA_mm, 'edt_hA', P.heightA_mm);
[S.h, yTop] = addPanelRegion(S.h, fig, x0, yTop, panelW, 'Region B  (y > 0)', ...
                             'edt_wB', P.widthB_mm, 'edt_hB', P.heightB_mm);
[S.h, yTop] = addPanelField(S.h, fig, x0, yTop, panelW, P, S.expandModes);

% ---------------- buttons (PLAN2.md section 1: six, in workflow order) --------
%   NB: positions are computed inline, NOT via an anonymous helper -- a MATLAB
%   anonymous function captures yB by VALUE at creation, which would stack every
%   button at the same place.
bw = panelW; bh = 30; gap = 5;
yB = yTop - 8;

S.h.btn_rashi = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'pixels', ...
    'String', '1.  Calculate dose  (RaShi)', 'Position', [x0 yB-bh bw bh], ...
    'FontWeight', 'bold', 'Tag', 'btn_rashi', 'Enable', 'on', ...
    'Callback', @(s,e) onCalcRashi(ancestorFig(s)));
S.h.btn_calc = S.h.btn_rashi;        % round-1 alias: T01-T35 look up S.h.btn_calc
yB = yB - bh - gap;

S.h.btn_2drm = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'pixels', ...
    'String', '2.  Calculate dose  (2DRM local)', 'Position', [x0 yB-bh bw bh], ...
    'FontWeight', 'bold', 'Tag', 'btn_2drm', 'Enable', 'on', ...
    'Callback', @(s,e) onCalc2drmLocal(ancestorFig(s)));
yB = yB - bh - gap;

S.h.btn_diff = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'pixels', ...
    'String', '3.  See difference', 'Position', [x0 yB-bh bw bh], ...
    'FontWeight', 'bold', 'Tag', 'btn_diff', 'Enable', 'off', ...
    'Callback', @(s,e) onSeeDifference(ancestorFig(s)));
yB = yB - bh - gap;

S.h.btn_apply = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'pixels', ...
    'String', '4.  Apply non-locality model', 'Position', [x0 yB-bh bw bh], ...
    'FontWeight', 'bold', 'Tag', 'btn_apply', 'Enable', 'off', ...
    'Callback', @(s,e) onApplyNonlocality(ancestorFig(s)));
yB = yB - bh - gap;

S.h.btn_result = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'pixels', ...
    'String', '5.  Result  (11 figures)', 'Position', [x0 yB-bh bw bh], ...
    'FontWeight', 'bold', 'Tag', 'btn_result', 'Enable', 'on', ...
    'Callback', @(s,e) onResult(ancestorFig(s)));
yB = yB - bh - gap;

% Figure-selection listbox (PLAN3.md section 6.4, user decision section 11.2):
% multi-select (Max-Min > 1 is the uicontrol idiom), all 11 selected by default,
% so pressing Result without touching it behaves exactly as before.
lbH = 150;
figKeys = resultFigureKeys();
S.h.lst_figs = uicontrol(fig, 'Style', 'listbox', 'Units', 'pixels', ...
    'Position', [x0 yB-lbH bw lbH], 'Tag', 'lst_figs', 'FontSize', 8, ...
    'String', figKeys, 'Min', 0, 'Max', 2, 'Value', 1:numel(figKeys));
yB = yB - lbH - gap;

S.h.btn_reset = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'pixels', ...
    'String', 'Reset', 'Position', [x0 yB-bh bw bh], ...
    'Tag', 'btn_reset', 'Enable', 'on', ...
    'Callback', @(s,e) onReset(ancestorFig(s)));
yB = yB - bh - gap;

% 7th button (PLAN3.md section 2.2 / P5): exports whatever Result figures are
% currently open, at the Python reference dpi -- see onSaveFigs/btn_savefigs.
S.h.btn_savefigs = uicontrol(fig, 'Style', 'pushbutton', 'Units', 'pixels', ...
    'String', 'Save figures (PNG)', 'Position', [x0 yB-bh bw bh], ...
    'Tag', 'btn_savefigs', 'Enable', 'on', ...
    'Callback', @(s,e) onSaveFigs(ancestorFig(s)));

% ---------------- information box (PLAN2.md section 4) ------------------------
S.h.txt_info = uicontrol(fig, 'Style', 'text', 'String', '', ...
    'Units', 'pixels', 'Position', [x0 50 panelW 136], ...
    'HorizontalAlignment', 'left', 'FontName', 'Courier New', 'FontSize', 8, ...
    'BackgroundColor', [1 1 1], 'Tag', 'txt_info');

% ---------------- status (transient one-liner) --------------------------------
S.h.txt_status = uicontrol(fig, 'Style', 'text', 'String', 'Ready.', ...
    'Units', 'pixels', 'Position', [x0 8 W-2*x0 34], ...
    'HorizontalAlignment', 'left', 'BackgroundColor', [1 1 0.88], ...
    'Tag', 'txt_status');

% ---------------- axes --------------------------------------------------------
ax0 = x0 + panelW + 30;
axW = (W - ax0 - 40) / 2;
S.h.ax_geom   = axes('Parent', fig, 'Units', 'pixels', ...
                     'Position', [ax0 H-280 axW-40 230], 'Tag', 'ax_geom');
S.h.ax_prof   = axes('Parent', fig, 'Units', 'pixels', ...
                     'Position', [ax0+axW+10 H-280 axW-60 230], 'Tag', 'ax_prof');
dw = (W - ax0 - 50) / 3;
S.h.ax_before = axes('Parent', fig, 'Units', 'pixels', ...
                     'Position', [ax0 H-580 dw-55 215], 'Tag', 'ax_before');
S.h.ax_after  = axes('Parent', fig, 'Units', 'pixels', ...
                     'Position', [ax0+dw H-580 dw-55 215], 'Tag', 'ax_after');
S.h.ax_diff   = axes('Parent', fig, 'Units', 'pixels', ...
                     'Position', [ax0+2*dw H-580 dw-55 215], 'Tag', 'ax_diff');
S.h.ax_dd     = axes('Parent', fig, 'Units', 'pixels', ...
                     'Position', [ax0 60 W-ax0-60 180], 'Tag', 'ax_dd');

guidata(fig, S);
markDoseStale(fig, false);
updateInfoBox(fig);
end


function f = ancestorFig(h)
%ANCESTORFIG  Figure that owns a uicontrol.
f = ancestor(h, 'figure');
end


function [h, yOut] = addPanelBeam(h, fig, x0, yTop, w, P, energies)
ph = 90;
p = uipanel(fig, 'Title', 'Beam', 'Units', 'pixels', ...
            'Position', [x0 yTop-ph w ph], 'FontWeight', 'bold');
uicontrol(p, 'Style', 'text', 'String', 'Energy [MeV/u]', 'Units', 'pixels', ...
          'Position', [8 44 110 16], 'HorizontalAlignment', 'left');
strs = arrayfun(@(e) sprintf('%g', e), energies, 'UniformOutput', false);
idx  = find(abs(energies - P.energy_MeVu) < 1e-9, 1);
if isempty(idx), idx = find(energies == 240, 1); end
h.pop_energy = uicontrol(p, 'Style', 'popupmenu', 'String', strs, 'Value', idx, ...
    'Units', 'pixels', 'Position', [125 42 100 22], 'Tag', 'pop_energy', ...
    'Callback', @(s,e) onParamChanged(ancestorFig(s)));
uicontrol(p, 'Style', 'text', 'String', 'FWHM [mm] 6-10', 'Units', 'pixels', ...
          'Position', [8 16 110 16], 'HorizontalAlignment', 'left');
h.edt_fwhm = uicontrol(p, 'Style', 'edit', 'String', num2str(P.fwhm0_mm, '%g'), ...
    'Units', 'pixels', 'Position', [125 14 100 22], 'Tag', 'edt_fwhm', ...
    'Callback', @(s,e) onParamChanged(ancestorFig(s)));
yOut = yTop - ph - 8;
end


function [h, yOut] = addPanelRegion(h, fig, x0, yTop, w, title, tagW, valW, tagH, valH)
ph = 90;
p = uipanel(fig, 'Title', title, 'Units', 'pixels', ...
            'Position', [x0 yTop-ph w ph], 'FontWeight', 'bold');
uicontrol(p, 'Style', 'text', 'String', 'width [mm]', 'Units', 'pixels', ...
          'Position', [8 44 110 16], 'HorizontalAlignment', 'left');
h.(tagW) = uicontrol(p, 'Style', 'edit', 'String', num2str(valW, '%g'), ...
    'Units', 'pixels', 'Position', [125 42 100 22], 'Tag', tagW, ...
    'Callback', @(s,e) onParamChanged(ancestorFig(s)));
uicontrol(p, 'Style', 'text', 'String', 'height [mm WEPL]', 'Units', 'pixels', ...
          'Position', [8 16 110 16], 'HorizontalAlignment', 'left');
h.(tagH) = uicontrol(p, 'Style', 'edit', 'String', num2str(valH, '%g'), ...
    'Units', 'pixels', 'Position', [125 14 100 22], 'Tag', tagH, ...
    'Callback', @(s,e) onParamChanged(ancestorFig(s)));
yOut = yTop - ph - 8;
end


function [h, yOut] = addPanelField(h, fig, x0, yTop, w, P, modes)
ph = 150;
p = uipanel(fig, 'Title', 'Field / numerics', 'Units', 'pixels', ...
            'Position', [x0 yTop-ph w ph], 'FontWeight', 'bold');
uicontrol(p, 'Style', 'text', 'String', 'x-extent [mm]', 'Units', 'pixels', ...
          'Position', [8 104 110 16], 'HorizontalAlignment', 'left');
h.edt_fx = uicontrol(p, 'Style', 'edit', 'String', num2str(P.fieldX_mm, '%g'), ...
    'Units', 'pixels', 'Position', [125 102 100 22], 'Tag', 'edt_fx', ...
    'Callback', @(s,e) onParamChanged(ancestorFig(s)));
uicontrol(p, 'Style', 'text', 'String', 'spacing [mm]', 'Units', 'pixels', ...
          'Position', [8 76 110 16], 'HorizontalAlignment', 'left');
h.edt_D = uicontrol(p, 'Style', 'edit', 'String', num2str(P.spacing_mm, '%g'), ...
    'Units', 'pixels', 'Position', [125 74 100 22], 'Tag', 'edt_D', ...
    'Callback', @(s,e) onParamChanged(ancestorFig(s)));
uicontrol(p, 'Style', 'text', 'String', 'outside pins', 'Units', 'pixels', ...
          'Position', [8 48 110 16], 'HorizontalAlignment', 'left');
idx = find(strcmpi(modes, P.expand_mode), 1);
if isempty(idx), idx = 2; end
h.pop_expand = uicontrol(p, 'Style', 'popupmenu', 'String', modes, 'Value', idx, ...
    'Units', 'pixels', 'Position', [125 46 100 22], 'Tag', 'pop_expand', ...
    'Callback', @(s,e) onParamChanged(ancestorFig(s)));
h.chk_hifi = uicontrol(p, 'Style', 'checkbox', 'String', 'High fidelity (0.5 mm pixel)', ...
    'Units', 'pixels', 'Position', [10 24 215 20], 'Tag', 'chk_hifi', ...
    'Callback', @(s,e) onParamChanged(ancestorFig(s)));
h.chk_exact = uicontrol(p, 'Style', 'checkbox', 'String', 'Compare exact 2DRM', ...
    'Units', 'pixels', 'Position', [10 4 215 20], 'Tag', 'chk_exact', ...
    'Callback', @(s,e) onParamChanged(ancestorFig(s)));
yOut = yTop - ph - 8;
end


function d = emptyDose()
%EMPTYDOSE  Empty dose container (PLAN2.md section 2).
%   rashi_Gy and local_Gy are the two IMMUTABLE originals, each written once by
%   its own Calculate button and fingerprinted by guard / guardLocal.
%   Everything else is derived and may be rebuilt at will.
d = struct('rashi_Gy',   [], ...   % RaShi dose [Gy]            (nz,nx,ny) ORIGINAL
           'local_Gy',   [], ...   % local 2DRM dose [Gy]       (nz,nx,ny) ORIGINAL
           'nl_Gy',      [], ...   % non-locality term dD [Gy]  (nz,nx,ny) derived
           'after_Gy',   [], ...   % local_Gy + nl_Gy [Gy]                 derived
           'exact_Gy',   [], ...   % exact 2DRM dose [Gy] (optional, chk_exact)
           'diff_pct',   [], ...   % displayed difference map [% of max rashi]
           'diffMode',   '',  ...  % '' | 'before' | 'after'
           'nlGridMismatch', false, ... % matchGrid had to crop/pad (DEFECT-3/4, flagged not fixed)
           'zEdges_mm',  [], 'xEdges_mm', [], 'yEdges_mm', [], ...
           'guard',      [], ...   % fingerprint of rashi_Gy
           'guardLocal', [], ...   % fingerprint of local_Gy
           'Pused',      [], ...   % params of whichever dose was computed last
           'PusedRashi', [], ...   % params the RaShi dose was computed with
           'PusedLocal', [], ...   % params the local 2DRM dose was computed with
           'PusedExact', []);      % params the exact 2DRM dose was computed with
end


%% ============================================================ CALLBACKS

function P = readParams(fig)
%READPARAMS  Collect the raw (unvalidated) parameters from the controls.
S = guidata(fig);
P = S.P;
P.energy_MeVu = S.energies_MeVu(get(S.h.pop_energy, 'Value'));
P.fwhm0_mm    = str2double(get(S.h.edt_fwhm, 'String'));
P.widthA_mm   = str2double(get(S.h.edt_wA,   'String'));
P.heightA_mm  = str2double(get(S.h.edt_hA,   'String'));
P.widthB_mm   = str2double(get(S.h.edt_wB,   'String'));
P.heightB_mm  = str2double(get(S.h.edt_hB,   'String'));
P.fieldX_mm   = str2double(get(S.h.edt_fx,   'String'));
P.spacing_mm  = str2double(get(S.h.edt_D,    'String'));
modes = get(S.h.pop_expand, 'String');
P.expand_mode = modes{get(S.h.pop_expand, 'Value')};
if get(S.h.chk_hifi, 'Value')
    P.lateral_pixel_mm = 0.5;     % Python reference grid
else
    P.lateral_pixel_mm = 1.0;     % coarse, interactive
end
end


function onParamChanged(fig)
%ONPARAMCHANGED  Re-validate, rewrite the fields, redraw geometry, mark dose stale.
S = guidata(fig);
Praw = readParams(fig);

% Non-numeric or empty entries revert to the previous accepted value (T28/T29).
flds = {'fwhm0_mm','edt_fwhm'; 'widthA_mm','edt_wA'; 'heightA_mm','edt_hA'; ...
        'widthB_mm','edt_wB'; 'heightB_mm','edt_hB'; 'fieldX_mm','edt_fx'; ...
        'spacing_mm','edt_D'};
reverted = {};
for i = 1:size(flds,1)
    f = flds{i,1};
    if ~isscalar(Praw.(f)) || ~isfinite(Praw.(f))
        Praw.(f) = S.P.(f);
        reverted{end+1} = f;    %#ok<AGROW>
    end
end

[P, msgs, ok] = validateParams(Praw, S.P);
if ~isempty(reverted)
    msgs = [{sprintf('Invalid entry in: %s - previous value restored.', ...
                     strjoin(reverted, ', '))}, msgs];
end

S.P = P;
S.okToCalculate = ok;
guidata(fig, S);
writeFields(fig, P);                      % rewrite snapped/clamped values

updateGeometryPlot(fig);
markDoseStale(fig, true);

updateInfoBox(fig);          % model block depends on parameters only

if isempty(msgs)
    C = derivedCounts(P);
    setStatus(fig, 'Geometry: %d x %d spots of %.3g mm | K_A = %d, K_B = %d levels.', ...
              C.n_rows_x, C.n_cols_zoneA + C.n_cols_zoneB, C.D_mm, C.K_A, C.K_B);
else
    setStatus(fig, '%s', strjoin(msgs, '  '));
end
updateButtonStates(fig);
end


function writeFields(fig, P)
%WRITEFIELDS  Push validated values back into the edit boxes.
S = guidata(fig);
set(S.h.edt_fwhm, 'String', num2str(P.fwhm0_mm,  '%g'));
set(S.h.edt_wA,   'String', num2str(P.widthA_mm, '%g'));
set(S.h.edt_hA,   'String', num2str(P.heightA_mm,'%g'));
set(S.h.edt_wB,   'String', num2str(P.widthB_mm, '%g'));
set(S.h.edt_hB,   'String', num2str(P.heightB_mm,'%g'));
set(S.h.edt_fx,   'String', num2str(P.fieldX_mm, '%g'));
set(S.h.edt_D,    'String', num2str(P.spacing_mm,'%g'));
idx = find(abs(S.energies_MeVu - P.energy_MeVu) < 1e-9, 1);
if ~isempty(idx), set(S.h.pop_energy, 'Value', idx); end
end


function s = onoff(tf)
if tf, s = 'on'; else, s = 'off'; end
end


function [ok, P, C, ddd, rng, spots, N, pins, info, grid, sig0, zMax] = prepareCommon(fig, what)
%PREPARECOMMON  Shared set-up for both Calculate buttons.
%   Returns ok = false (and a status message) when the parameters cannot make a dose.
ok = false;  P = []; C = []; ddd = []; rng = []; spots = []; N = [];
pins = []; info = []; grid = []; sig0 = []; zMax = [];
S = guidata(fig);
P = S.P;
if isfield(S, 'okToCalculate') && ~S.okToCalculate
    setStatus(fig, 'Cannot calculate: both region heights are 0.');
    return;
end
C = derivedCounts(P);
if C.K <= 0
    setStatus(fig, 'Cannot calculate: no levels (both heights are 0).');
    return;
end
setStatus(fig, 'Calculating %s ...', what); drawnow;

[ddd, rng]   = loadTables(P);
spots        = makeSpots(P);
N            = rashiWeights(P, spots);
[pins, info] = buildPins(P, spots);

halfX = max(abs(info.pinned_x_mm)) + P.lateral_margin_mm;
halfY = max(abs(info.pinned_y_mm)) + P.lateral_margin_mm;
grid  = makeGrid(halfX, halfY, P.lateral_pixel_mm);
sig0  = P.fwhm0_mm * FWHM2SIG();
if P.z_max_mm > 0, zMax = P.z_max_mm; else, zMax = ceil(dddPeakDepth(ddd) + 30.0); end
ok = true;
end


function onCalcRashi(fig)
%ONCALCRASHI  Button 1.  RaShi dose (spot-labelled, WATER transport lp_R).
%   Stored as an immutable original; only the Apply-derived state is cleared so
%   a previously computed local 2DRM survives (order independence, PLAN2 T43).
t0 = tic;
[ok, P, C, ddd, rng, spots, N, pins, info, grid, sig0, zMax] = ...
    prepareCommon(fig, 'RaShi dose');
if ~ok, return; end

F_R  = fluenceRashi(grid, spots, N, sig0);
lp_R = levelProps(P, 'rashi', rng);
[dose_R, zEdges] = computeDose(P, grid, F_R, lp_R, ddd, zMax);
% PLAN3 section 5 (P1): block-average the pixel-grid dose to 1 mm voxels,
% matching Python's analysis.to_voxels -- every stored dose and every figure
% is built from the VOXEL grid from here on; S.cache.grid keeps the pixel
% grid for fluence work (e.g. the geometry plot, buildPins).
[dose_R, xEdgesV, yEdgesV] = toVoxels(dose_R, grid, P.voxel_mm);

S = guidata(fig);
S.dose = clearDerived(S.dose);                 % keep local_Gy, drop Apply state
S.dose.rashi_Gy   = dose_R;                    % <-- written ONCE, never again
S.dose.guard      = doseGuard(dose_R);
S.dose.PusedRashi = P;
S.dose.Pused      = P;
S.dose.zEdges_mm  = zEdges;
S.dose.xEdges_mm  = xEdgesV;
S.dose.yEdges_mm  = yEdgesV;
S.applyCount      = 0;
S.cache.pins = pins;  S.cache.info = info;  S.cache.grid = grid;
guidata(fig, S);

markDoseStale(fig, false);
updateButtonStates(fig);
updateDosePlots(fig);
updateInfoBox(fig);
assertGuard(guidata(fig));
setStatus(fig, ['RaShi dose done in %.1f s (%d x %d pixels of %.3g mm, %d levels, ' ...
                '%d pins). Max %.4g Gy.'], ...
          toc(t0), grid.nx, grid.ny, grid.h_mm, C.K, numel(pins), max(dose_R(:)));
end


function onCalc2drmLocal(fig)
%ONCALC2DRMLOCAL  Button 2.  LOCAL 2DRM dose.
%
%   Identity P1 (PLAN2.md section 0): a local 2DRM modulates every spot by its
%   OWN pin only, which makes its level-resolved fluence identical to the RaShi
%   fluence.  So we reuse fluenceRashi and change ONLY the transport, water
%   (lp_R) -> PMMA (lp_M).  The resulting dose therefore differs from the RaShi
%   dose through the material/MCS term alone (about +1 % in the zone cores) --
%   that small number is CORRECT, not a bug.  Non-locality is added separately
%   by button 4.
t0 = tic;
[ok, P, C, ddd, rng, spots, N, pins, info, grid, sig0, zMax] = ...
    prepareCommon(fig, 'local 2DRM dose');
if ~ok, return; end

F_local = fluenceRashi(grid, spots, N, sig0);   % identity P1: F_local == F_R
lp_M    = levelProps(P, '2drm', rng);           % PMMA transport
[dose_L, zEdges] = computeDose(P, grid, F_local, lp_M, ddd, zMax);
% PLAN3 section 5 (P1): block-average to 1 mm voxels, same as onCalcRashi.
[dose_L, xEdgesV, yEdgesV] = toVoxels(dose_L, grid, P.voxel_mm);

S = guidata(fig);
S.dose = clearDerived(S.dose);                 % keep rashi_Gy, drop Apply state
S.dose.local_Gy   = dose_L;                    % <-- written ONCE, never again
S.dose.guardLocal = doseGuard(dose_L);
S.dose.PusedLocal = P;
S.dose.Pused      = P;
S.dose.zEdges_mm  = zEdges;
S.dose.xEdges_mm  = xEdgesV;
S.dose.yEdges_mm  = yEdgesV;
S.applyCount      = 0;
S.cache.pins = pins;  S.cache.info = info;  S.cache.grid = grid;
guidata(fig, S);

% Optional exact 2DRM (position-labelled fluence): the validation target that
% the local + model path is compared against.  Only with the checkbox ticked.
S = guidata(fig);
if get(S.h.chk_exact, 'Value')
    setStatus(fig, 'Calculating exact 2DRM dose (position-labelled) ...'); drawnow;
    W      = sum(N, 2);
    F_M    = fluence2drm(grid, spots, W, sig0, pins, P.spacing_mm, C.K);
    dose_M = computeDose(P, grid, F_M, lp_M, ddd, zMax);
    dose_M = toVoxels(dose_M, grid, P.voxel_mm);    % same grid -> same voxel size as local_Gy
    % Stamp it with the parameters it was computed from, exactly as rashi_Gy and
    % local_Gy are stamped.  Without this stamp a stale exact dose survives a
    % geometry change and is silently differenced against the new doses (D1).
    S = guidata(fig);
    S.dose.exact_Gy   = dose_M;
    S.dose.PusedExact = P;
    guidata(fig, S);
end

markDoseStale(fig, false);
updateButtonStates(fig);
updateDosePlots(fig);
updateInfoBox(fig);
assertGuard(guidata(fig));
setStatus(fig, ['Local 2DRM dose done in %.1f s. Max %.4g Gy. ' ...
                'Fluence identical to RaShi (identity P1); PMMA transport only.'], ...
          toc(t0), max(dose_L(:)));
end


function d = clearDerived(d)
%CLEARDERIVED  Drop everything derived from the doses, keep both originals.
d.nl_Gy          = [];
d.after_Gy       = [];
d.diff_pct       = [];
d.diffMode       = '';
d.nlGridMismatch = false;
end


function tf = sameGeom(P1, P2)
%SAMEGEOM  True when two parameter sets would produce the same dose grid.
%   Used by the mixed-geometry guard: a difference must never be formed from
%   two doses computed with different geometries (PLAN2.md section 1, T44).
tf = ~isempty(P1) && ~isempty(P2) && isequaln(P1, P2);
end


function tf = exactIsCurrent(S)
%EXACTISCURRENT  True when exact_Gy exists AND belongs to the current geometry.
%   exact_Gy is optional (it is only produced with "Compare exact 2DRM" ticked)
%   and it deliberately SURVIVES Reset, because it is a calculated dose rather
%   than Apply state and the user requires Reset not to force a recomputation.
%   It must therefore be guarded rather than cleared: a stale exact dose left
%   over from a previous geometry must never be differenced against the current
%   doses.  Every consumer of exact_Gy goes through this test (defect D1).
tf = ~isempty(S.dose.exact_Gy) && sameGeom(S.dose.PusedExact, S.dose.PusedLocal);
end


function [M, src] = pyRefDose(S)
%PYREFDOSE  The array Python calls `M` (analysis.py), with an honest fallback.
%   Python's M is the EXACT, position-labelled 2DRM dose.  Use it when a
%   current one exists; otherwise fall back and say so in `src`, rather than
%   silently plotting a different quantity under a title that claims to be
%   the Python reference (PLAN3.md section 5.3).
if exactIsCurrent(S)
    M = S.dose.exact_Gy;  src = 'exact';
elseif ~isempty(S.dose.after_Gy)
    M = S.dose.after_Gy;  src = 'local+model';
else
    M = S.dose.local_Gy;  src = 'local';
end
end


function onSeeDifference(fig)
%ONSEEDIFFERENCE  Button 3.  (local - rashi) / max(rashi) * 100  [%].
%   Before Apply this is the MATERIAL term alone (see onCalc2drmLocal).
S = guidata(fig);
if ~bothDosesReady(fig), return; end
R = S.dose.rashi_Gy;
L = S.dose.local_Gy;
S.dose.diff_pct = (L - R) / max(R(:)) * 100;      % PLAN2.md section 3
S.dose.diffMode = 'before';
guidata(fig, S);
assertGuard(guidata(fig));
updateDosePlots(fig);
updateInfoBox(fig);
d = S.dose.diff_pct;
setStatus(fig, ['Difference (before Apply) = (2DRM local - RaShi) / max(RaShi): ' ...
                '%+.2f .. %+.2f %%. This is the MATERIAL term alone - a small ' ...
                'value here is correct.'], min(d(:)), max(d(:)));
end


function ok = bothDosesReady(fig)
%BOTHDOSESREADY  Guard shared by See difference and Apply.
S  = guidata(fig);
ok = false;
if isempty(S.dose.rashi_Gy)
    setStatus(fig, 'Press "1. Calculate dose (RaShi)" first.');  return;
end
if isempty(S.dose.local_Gy)
    setStatus(fig, 'Press "2. Calculate dose (2DRM local)" first.');  return;
end
if ~sameGeom(S.dose.PusedRashi, S.dose.PusedLocal)
    setStatus(fig, ['The two doses were computed with DIFFERENT parameters. ' ...
                    'Re-run both Calculate buttons before taking a difference.']);
    return;
end
ok = true;
end


function onApplyNonlocality(fig)
%ONAPPLYNONLOCALITY  Button 4.  Add the non-locality term to the LOCAL 2DRM.
%
%   USER-CONFIRMED SEMANTICS.  The model is applied to the LOCAL 2DRM dose, not
%   to the RaShi dose, so that each button contributes exactly one effect:
%
%       D_RaShi --[material]--> D_local --[non-locality]--> D_exact
%
%   after_Gy = local_Gy + nl_Gy  (NOT rashi_Gy + nl_Gy).  Applying the model to
%   the RaShi dose instead would omit the material term, so one button would be
%   doing two jobs.  Applying it to the EXACT 2DRM would double-count, because
%   the exact 2DRM already contains the non-locality.
%
%   MUST NOT write to rashi_Gy or local_Gy, and MUST NOT accumulate: nl_Gy is
%   recomputed from the parameters on every press, so N presses give a
%   bit-identical after_Gy.
S = guidata(fig);
if isempty(S.dose.rashi_Gy)
    setStatus(fig, 'Press "1. Calculate dose (RaShi)" first.');
    return;
end
% The GUI button is gated on both doses, but the programmatic API (and the
% round-1 test sequence calculate -> applynl) may arrive here without a local
% 2DRM.  Compute it rather than failing, and say so.
if isempty(S.dose.local_Gy)
    setStatus(fig, 'No local 2DRM dose yet - computing it first ...'); drawnow;
    onCalc2drmLocal(fig);
    S = guidata(fig);
    if isempty(S.dose.local_Gy)
        setStatus(fig, 'Could not compute the local 2DRM dose; Apply aborted.');
        return;
    end
end
if ~bothDosesReady(fig), return; end

t0 = tic;
setStatus(fig, 'Applying the non-locality model ...'); drawnow;

S = guidata(fig);
P = S.dose.PusedLocal;                 % the parameters both doses belong to
[ddd, rng] = loadTables(P);
half_mm = ceil(max(abs([S.dose.xEdges_mm(1), S.dose.xEdges_mm(end), ...
                        S.dose.yEdges_mm(1), S.dose.yEdges_mm(end)])));

nl_Gy = predictDeltaDose(P, ddd, rng, P.voxel_mm, half_mm);

% resample onto the stored dose grid if the voxel averaging changed the size.
% DEFECT-3/DEFECT-4 (see matchGrid, below): flag -- not fix -- a mismatch.
lastwarn('');
nl_Gy = matchGrid(nl_Gy, size(S.dose.rashi_Gy));
[wmsg, wid] = lastwarn();
mismatch = strcmp(wid, 'drm2d:nlGridMismatch');

S = guidata(fig);
R = S.dose.rashi_Gy;
S.dose.nl_Gy          = nl_Gy;                      % fresh every press
S.dose.after_Gy       = S.dose.local_Gy + nl_Gy;    % derived, never in place
S.dose.diff_pct       = (S.dose.after_Gy - R) / max(R(:)) * 100;   % PLAN2.md section 3
S.dose.diffMode       = 'after';
S.dose.nlGridMismatch = mismatch;
S.applyCount          = S.applyCount + 1;
guidata(fig, S);

assertGuard(guidata(fig));              % both originals must be untouched
updateDosePlots(fig);
updateInfoBox(fig);
d = S.dose.diff_pct;
if mismatch
    setStatus(fig, ['Non-locality applied (press %d) in %.1f s, but !! nl grid mismatch - ' ...
                    'see DEFECTS.md (DEFECT-3/DEFECT-4): %s'], S.applyCount, toc(t0), wmsg);
else
    setStatus(fig, ['Non-locality applied to the LOCAL 2DRM (press %d) in %.1f s. ' ...
                    'Difference now (local + dD - RaShi)/max(RaShi) = %+.2f .. %+.2f %%.'], ...
              S.applyCount, toc(t0), min(d(:)), max(d(:)));
end
end


function B = matchGrid(A, sz)
%MATCHGRID  Crop or zero-pad A to size sz (guards against an off-by-one grid).
%
%   DEFECT-3 / DEFECT-4 (matlab/DEFECTS.md, OPEN -- deliberately not fixed,
%   user deferred, PLAN3.md section 2.0 Q3: "flag it so I can check later").
%   This crop/pad branch is WRONG in general: it registers A against sz by
%   INDEX, not by coordinate, so on a non-square pinned area (fieldX_mm/2 ~=
%   max(widthA_mm, widthB_mm)) it can silently mis-place the non-locality term
%   by a whole pixel row/column (DEFECT-4's halfX ~= halfY case feeding
%   DEFECT-3's crop/pad here).
%
%   STRUCTURAL-INERTNESS ARGUMENT (PLAN3.md section 0.2, re-derived here so a
%   future reader does not have to): since toVoxels (above) now block-averages
%   rashi_Gy/local_Gy/exact_Gy to the SAME 1 mm voxel grid that foldSeparable
%   already produces for nl_Gy, onApplyNonlocality's half_mm (derived from the
%   stored dose edges) and predictDeltaDose's own pixelGridNL half-width agree
%   exactly WHENEVER THE PINNED AREA IS SQUARE -- which includes the
%   reference case and the tool's default geometry.  On a square grid
%   size(A) == sz always, so the branch below is UNREACHABLE and this
%   function is the identity.  It only fires (and only then does the
%   mis-registration above actually occur) for a non-square geometry in
%   high-fidelity mode.  Do not "fix" this by widening a tolerance -- the
%   mismatch is a real registration error, not a numerical one; the deferred
%   fix is to thread independent halfX_mm/halfY_mm through pixelGridNL,
%   deltaPhiPixels, foldSeparable and predictDeltaDose (see PLAN3.md
%   section 5.2(b) for the exact call-site recipe), after which this function
%   becomes provably unnecessary and can be deleted.
%
%   The warning below is a FLAG, not a fix: it fires only when this function
%   actually crops or pads, so a working-but-wrong run becomes loud instead of
%   silent, without turning it into a hard error (an assert would be a
%   behaviour change the user did not ask for).
B = zeros(sz);
n = min(size(A), sz);
if ~isequal(size(A), sz)
    warning('drm2d:nlGridMismatch', ...
            ['matchGrid is cropping/padding: nl term is %s but the dose is %s. ' ...
             'The non-locality term is now spatially MIS-REGISTERED (DEFECTS.md ' ...
             'DEFECT-3/DEFECT-4). Results in this state are not trustworthy.'], ...
            mat2str(size(A)), mat2str(sz));
end
B(1:n(1), 1:n(2), 1:n(3)) = A(1:n(1), 1:n(2), 1:n(3));
end


function onReset(fig)
%ONRESET  Button 6.  Clear the Apply-derived state ONLY.
%   User decision: both calculated doses survive, so Reset never costs a
%   20-40 s recomputation.  exact_Gy is likewise KEPT -- it is a calculated
%   dose (produced by button 2 with "Compare exact 2DRM" ticked), not Apply
%   state, and clearing it would contradict that decision.  See the report note.
%   A second Reset is a no-op.
S = guidata(fig);
had = ~isempty(S.dose.nl_Gy) || ~isempty(S.dose.after_Gy) || ~isempty(S.dose.diff_pct);
S.dose       = clearDerived(S.dose);
S.applyCount = 0;
guidata(fig, S);

assertGuard(guidata(fig));
updateButtonStates(fig);
updateDosePlots(fig);
updateInfoBox(fig);

if isempty(S.dose.rashi_Gy) && isempty(S.dose.local_Gy)
    setStatus(fig, 'Reset: nothing to clear.');
elseif had
    setStatus(fig, ['Reset: non-locality and difference cleared. ' ...
                    'Both calculated doses are unchanged.']);
else
    setStatus(fig, 'Reset: nothing to clear (both doses kept).');
end
end


function g = doseGuard(d)
%DOSEGUARD  Cheap fingerprint of the original dose array.
g = struct('sz', size(d), 's1', sum(d(:)), 's2', sum(d(:).^2));
end


function assertGuard(S)
%ASSERTGUARD  Verify that NEITHER original dose has been modified.
%   Runs at the end of every callback so corruption is caught where it happens.
checkOne(S.dose.rashi_Gy, S.dose.guard,      'RaShi');
checkOne(S.dose.local_Gy, S.dose.guardLocal, 'local 2DRM');

    function checkOne(d, g, label)
        if isempty(d) || isempty(g), return; end
        gn = doseGuard(d);
        ok = isequal(gn.sz, g.sz) && isequaln(gn.s1, g.s1) && isequaln(gn.s2, g.s2);
        if ~ok
            error('drm2d:immutable', ...
                  'The original %s dose was modified (guard mismatch). This is a bug.', ...
                  label);
        end
    end
end


function updateButtonStates(fig)
%UPDATEBUTTONSTATES  Enable/disable per the PLAN2.md section 1 state machine.
S  = guidata(fig);
ok = ~isfield(S, 'okToCalculate') || S.okToCalculate;
set(S.h.btn_rashi, 'Enable', onoff(ok));
set(S.h.btn_2drm,  'Enable', onoff(ok));

% Both doses must exist, be non-stale, and come from the SAME geometry.
stale = isfield(S, 'doseStale') && S.doseStale;
ready = ~isempty(S.dose.rashi_Gy) && ~isempty(S.dose.local_Gy) && ~stale && ...
        sameGeom(S.dose.PusedRashi, S.dose.PusedLocal);
set(S.h.btn_diff,  'Enable', onoff(ready));
set(S.h.btn_apply, 'Enable', onoff(ready));

% Result is always available: several of its figures need no dose at all.
set(S.h.btn_result, 'Enable', 'on');
end


function [ddd, rng] = loadTables(P)
%LOADTABLES  DDD + dE/dx tables for the current energy (both are cached).
tag = sprintf('%05d', round(P.energy_MeVu * 100));
ddd = readDDD(fullfile(P.basedata_dir, 'DDD', ['12C.H2O.MeV' tag '.ddd']));
rng = readDedx(fullfile(P.basedata_dir, '20040607.dedx'), '12C');
end


function setStatus(fig, fmt, varargin)
%SETSTATUS  Write the status line (and echo to the console when headless).
S = guidata(fig);
msg = sprintf(fmt, varargin{:});
if isfield(S.h, 'txt_status') && ishandle(S.h.txt_status)
    set(S.h.txt_status, 'String', msg);
end
if strcmpi(get(fig, 'Visible'), 'off')
    fprintf('[status] %s\n', msg);
end
end


%% ================================================================ PLOTS

function updateGeometryPlot(fig)
%UPDATEGEOMETRYPLOT  2DRM thickness map and a cut along y.  Live on every change.
S = guidata(fig);
P = S.P;
C = derivedCounts(P);
if C.K <= 0
    cla(S.h.ax_geom);  cla(S.h.ax_prof);
    title(S.h.ax_geom, 'no modulator (both heights 0)');
    return;
end

spots = makeSpots(P);
[pins, info] = buildPins(P, spots);
lw = levelWeplNominal(P);

lo = info.pinned_y_mm(1);  hi = info.pinned_y_mm(2);
step = max(0.05, (hi - lo) / 400);                 % keep the map cheap
g  = (lo + step/2) : step : (hi - step/2);
T  = thicknessMap(pins, lw, g, g, P.spacing_mm) / P.height_scale;   % PMMA mm

% --- top view
ax = S.h.ax_geom;  cla(ax);
imagesc(ax, g, g, T');                              % T is (ix,iy) -> transpose for imagesc
set(ax, 'YDir', 'normal');
axis(ax, 'image');
colormap(ax, cmapTable('viridis'));
cb = colorbar(ax);  cb.Label.String = 'PMMA height [mm]';
hold(ax, 'on');
plot(ax, [g(1) g(end)], [0 0], 'r-', 'LineWidth', 1);          % zone boundary
fx = P.fieldX_mm/2;
plot(ax, [-fx fx fx -fx -fx], [-P.widthA_mm -P.widthA_mm P.widthB_mm P.widthB_mm -P.widthA_mm], ...
     'w--', 'LineWidth', 0.8);                                  % planned field
plot(ax, spots.x_mm, spots.y_mm, 'w.', 'MarkerSize', 4);
hold(ax, 'off');
xlabel(ax, 'x [mm]');  ylabel(ax, 'y [mm]');
title(ax, sprintf('2DRM top view  (%d pins, %d rings)', info.n_pins, info.n_expand), ...
      'FontSize', 9);

% --- cut along y through a row of pin centres
ax = S.h.ax_prof;  cla(ax);
[~, ix] = min(abs(g - (spots.x_centers_mm(1))));
stairs(ax, g, T(ix,:)', 'k-', 'LineWidth', 1);
hold(ax, 'on');
yl = [0 max(1e-9, max(T(:)))*1.1];
plot(ax, [0 0], yl, 'r-', 'LineWidth', 0.8);
patch(ax, [-P.widthA_mm P.widthB_mm P.widthB_mm -P.widthA_mm], [yl(1) yl(1) yl(2) yl(2)], ...
      [0.92 0.92 0.92], 'EdgeColor', 'none', 'FaceAlpha', 0.5);
uistack(findobj(ax, 'Type', 'patch'), 'bottom');
hold(ax, 'off');
ylim(ax, yl);
xlabel(ax, 'y [mm]');  ylabel(ax, 'PMMA height [mm]');
title(ax, sprintf('cut at x = %.3g mm  (grey = planned field)', g(ix)), 'FontSize', 9);
end


function markDoseStale(fig, stale)
%MARKDOSESTALE  Grey the dose axes when the parameters no longer match the dose.
S = guidata(fig);
S.doseStale = logical(stale);
guidata(fig, S);
axs = [S.h.ax_before, S.h.ax_after, S.h.ax_diff, S.h.ax_dd];
haveDose = ~isempty(S.dose.rashi_Gy) || ~isempty(S.dose.local_Gy);
if stale && haveDose
    for a = axs
        set(a, 'Color', [0.88 0.88 0.88]);
        title(a, 'stale - press Calculate', 'FontSize', 9, 'Color', [0.4 0.4 0.4]);
    end
elseif stale
    for a = axs, set(a, 'Color', [0.95 0.95 0.95]); end
else
    for a = axs, set(a, 'Color', 'w'); end
end
updateButtonStates(fig);
end


function sl = sliceXAveraged(d, xEdges_mm, fieldX_mm)
%SLICEXAVERAGED  Average the dose over x inside the planned field -> (nz, ny).
%   DISPLAY ONLY (user-approved change to PLAN.md section 8): averaging over x
%   suppresses the 3 mm pin ripple so the non-locality dipole reads clearly.
%   The Python comparison must NOT use this - see sliceSingleX below.
xc = 0.5 * (xEdges_mm(1:end-1) + xEdges_mm(2:end));
m  = abs(xc) <= fieldX_mm/2;
if ~any(m), m = true(size(xc)); end
sl = squeeze(mean(d(:, m, :), 2));
end


function sl = sliceSingleX(d, xEdges_mm)
%SLICESINGLEX  y-z slice at the x pixel nearest x = +0.5 mm -> (nz, ny).
%   This is the slice Python's analysis.fig_dose_maps uses, so it is the one
%   the numerical comparison against the reference .mat files is based on.
%   Kept separate from the display slice on purpose.
xc = 0.5 * (xEdges_mm(1:end-1) + xEdges_mm(2:end));
[~, ix] = min(abs(xc - 0.5));
sl = squeeze(d(:, ix, :));
end


function updateDosePlots(fig)
%UPDATEDOSEPLOTS  RaShi / local 2DRM / difference, plus the depth-dose panel.
%   All three maps use the x-AVERAGED slice (user-approved display choice): it
%   suppresses the 3 mm pin ripple so the non-locality dipole reads clearly.
%   The Python comparison uses sliceSingleX instead -- see compareWithReference.
S = guidata(fig);
if isempty(S.dose.rashi_Gy) && isempty(S.dose.local_Gy), return; end
P = S.dose.Pused;
if isempty(P), return; end
ze = S.dose.zEdges_mm;  ye = S.dose.yEdges_mm;  xe = S.dose.xEdges_mm;
zc = 0.5*(ze(1:end-1) + ze(2:end));
yc = 0.5*(ye(1:end-1) + ye(2:end));
yl = [-max(P.widthA_mm, P.widthB_mm)-6, max(P.widthA_mm, P.widthB_mm)+6];

Rmax = 1;
if ~isempty(S.dose.rashi_Gy), Rmax = max(S.dose.rashi_Gy(:)); end

% --- panel 1: RaShi dose
ax = S.h.ax_before;  cla(ax);  set(ax, 'Color', 'w');
if ~isempty(S.dose.rashi_Gy)
    R = sliceXAveraged(S.dose.rashi_Gy, xe, P.fieldX_mm);
    imagesc(ax, yc, zc, R, [0 Rmax]);  set(ax, 'YDir', 'reverse');
    colormap(ax, cmapTable('jet'));
    xlabel(ax, 'y [mm]');  ylabel(ax, 'depth z [mm]');
    title(ax, '1. RaShi dose [Gy]', 'FontSize', 9, 'Color', 'k');
    xlim(ax, yl);  colorbar(ax);  addBoundaryLine(ax, zc);
else
    title(ax, '1. RaShi: press Calculate (RaShi)', 'FontSize', 9);
end

% --- panel 2: local 2DRM dose, with the model overlaid once Apply has run
ax = S.h.ax_after;  cla(ax);  set(ax, 'Color', 'w');
if ~isempty(S.dose.local_Gy)
    L = sliceXAveraged(S.dose.local_Gy, xe, P.fieldX_mm);
    imagesc(ax, yc, zc, L, [0 Rmax]);  set(ax, 'YDir', 'reverse');
    colormap(ax, cmapTable('jet'));
    xlabel(ax, 'y [mm]');
    xlim(ax, yl);  colorbar(ax);  addBoundaryLine(ax, zc);
    if ~isempty(S.dose.after_Gy)
        % Overlay: iso-dose contours of local + non-locality on the local map,
        % so the shift the model produces is visible in place.
        A = sliceXAveraged(S.dose.after_Gy, xe, P.fieldX_mm);
        hold(ax, 'on');
        lv = Rmax * [0.5 0.8 0.95];
        contour(ax, yc, zc, A, lv, 'LineColor', [0 0 0], 'LineWidth', 0.8);
        hold(ax, 'off');
        title(ax, '2. local 2DRM [Gy] + model overlay (black iso)', ...
              'FontSize', 9, 'Color', 'k');
    else
        title(ax, '2. local 2DRM dose [Gy]', 'FontSize', 9, 'Color', 'k');
    end
else
    title(ax, '2. local 2DRM: press Calculate (2DRM)', 'FontSize', 9);
end

% --- panel 3: the difference map (blank until See difference / Apply)
ax = S.h.ax_diff;  cla(ax);  set(ax, 'Color', 'w');
if ~isempty(S.dose.diff_pct)
    Dd  = sliceXAveraged(S.dose.diff_pct, xe, P.fieldX_mm);
    lim = max(0.5, max(abs(Dd(:))));
    imagesc(ax, yc, zc, Dd, [-lim lim]);  set(ax, 'YDir', 'reverse');
    colormap(ax, cmapTable('RdBu_r'));
    xlabel(ax, 'y [mm]');
    if strcmp(S.dose.diffMode, 'after')
        title(ax, '3. (local + dD - RaShi)/max(RaShi) [%]', 'FontSize', 9, 'Color', 'k');
    else
        title(ax, '3. (local - RaShi)/max(RaShi) [%]  (material only)', ...
              'FontSize', 9, 'Color', 'k');
    end
    xlim(ax, yl);  colorbar(ax);  addBoundaryLine(ax, zc);
else
    title(ax, '3. Difference: press "See difference"', 'FontSize', 9);
end

% --- depth dose at the two cells flanking the boundary
ax = S.h.ax_dd;  cla(ax);  set(ax, 'Color', 'w');  hold(ax, 'on');
ys   = [-P.spacing_mm/2, P.spacing_mm/2];
cols = {[0.1 0.3 0.8], [0.8 0.2 0.1]};
anyLine = false;
for n = 1:2
    [~, iy] = min(abs(yc - ys(n)));
    if ~isempty(S.dose.rashi_Gy)
        R = sliceXAveraged(S.dose.rashi_Gy, xe, P.fieldX_mm);
        plot(ax, zc, R(:,iy), '-', 'Color', cols{n}, 'LineWidth', 1.2, ...
             'DisplayName', sprintf('RaShi y = %+.1f', yc(iy)));
        anyLine = true;
    end
    if ~isempty(S.dose.local_Gy)
        L = sliceXAveraged(S.dose.local_Gy, xe, P.fieldX_mm);
        plot(ax, zc, L(:,iy), '--', 'Color', cols{n}, 'LineWidth', 1.1, ...
             'DisplayName', sprintf('2DRM local y = %+.1f', yc(iy)));
        anyLine = true;
    end
    if ~isempty(S.dose.after_Gy)
        A = sliceXAveraged(S.dose.after_Gy, xe, P.fieldX_mm);
        plot(ax, zc, A(:,iy), ':', 'Color', cols{n}, 'LineWidth', 1.6, ...
             'DisplayName', sprintf('local+dD y = %+.1f', yc(iy)));
        anyLine = true;
    end
end
hold(ax, 'off');
xlabel(ax, 'depth z [mm]');  ylabel(ax, 'dose [Gy]');
title(ax, 'Depth dose either side of the zone boundary', 'FontSize', 9, 'Color', 'k');
if anyLine, legend(ax, 'Location', 'northwest', 'FontSize', 7); end
grid(ax, 'on');
end


function addBoundaryLine(ax, zc)
hold(ax, 'on');
plot(ax, [0 0], [zc(1) zc(end)], 'w-', 'LineWidth', 0.7);
hold(ax, 'off');
end


function cmap = cmapTable(name)
%CMAPTABLE  matplotlib colormaps as 256x3 RGB in [0,1].
%   name: 'viridis' | 'magma' | 'jet' | 'RdBu_r'
%   Generated from matplotlib 3.11.2 by the snippet in PLAN3.md section 4.4.
%   Embedded literally because MATLAB has no equivalent of any of the four:
%   its own `jet` differs from matplotlib's by up to 0.131 per channel (PLAN3 section 0.1 C1).
persistent T
if isempty(T)
    T = struct();
    T.viridis = [ ...
        0.267004 0.004874 0.329415; 0.268510 0.009605 0.335427; 0.269944 0.014625 0.341379; 0.271305 0.019942 0.347269;
        0.272594 0.025563 0.353093; 0.273809 0.031497 0.358853; 0.274952 0.037752 0.364543; 0.276022 0.044167 0.370164;
        0.277018 0.050344 0.375715; 0.277941 0.056324 0.381191; 0.278791 0.062145 0.386592; 0.279566 0.067836 0.391917;
        0.280267 0.073417 0.397163; 0.280894 0.078907 0.402329; 0.281446 0.084320 0.407414; 0.281924 0.089666 0.412415;
        0.282327 0.094955 0.417331; 0.282656 0.100196 0.422160; 0.282910 0.105393 0.426902; 0.283091 0.110553 0.431554;
        0.283197 0.115680 0.436115; 0.283229 0.120777 0.440584; 0.283187 0.125848 0.444960; 0.283072 0.130895 0.449241;
        0.282884 0.135920 0.453427; 0.282623 0.140926 0.457517; 0.282290 0.145912 0.461510; 0.281887 0.150881 0.465405;
        0.281412 0.155834 0.469201; 0.280868 0.160771 0.472899; 0.280255 0.165693 0.476498; 0.279574 0.170599 0.479997;
        0.278826 0.175490 0.483397; 0.278012 0.180367 0.486697; 0.277134 0.185228 0.489898; 0.276194 0.190074 0.493001;
        0.275191 0.194905 0.496005; 0.274128 0.199721 0.498911; 0.273006 0.204520 0.501721; 0.271828 0.209303 0.504434;
        0.270595 0.214069 0.507052; 0.269308 0.218818 0.509577; 0.267968 0.223549 0.512008; 0.266580 0.228262 0.514349;
        0.265145 0.232956 0.516599; 0.263663 0.237631 0.518762; 0.262138 0.242286 0.520837; 0.260571 0.246922 0.522828;
        0.258965 0.251537 0.524736; 0.257322 0.256130 0.526563; 0.255645 0.260703 0.528312; 0.253935 0.265254 0.529983;
        0.252194 0.269783 0.531579; 0.250425 0.274290 0.533103; 0.248629 0.278775 0.534556; 0.246811 0.283237 0.535941;
        0.244972 0.287675 0.537260; 0.243113 0.292092 0.538516; 0.241237 0.296485 0.539709; 0.239346 0.300855 0.540844;
        0.237441 0.305202 0.541921; 0.235526 0.309527 0.542944; 0.233603 0.313828 0.543914; 0.231674 0.318106 0.544834;
        0.229739 0.322361 0.545706; 0.227802 0.326594 0.546532; 0.225863 0.330805 0.547314; 0.223925 0.334994 0.548053;
        0.221989 0.339161 0.548752; 0.220057 0.343307 0.549413; 0.218130 0.347432 0.550038; 0.216210 0.351535 0.550627;
        0.214298 0.355619 0.551184; 0.212395 0.359683 0.551710; 0.210503 0.363727 0.552206; 0.208623 0.367752 0.552675;
        0.206756 0.371758 0.553117; 0.204903 0.375746 0.553533; 0.203063 0.379716 0.553925; 0.201239 0.383670 0.554294;
        0.199430 0.387607 0.554642; 0.197636 0.391528 0.554969; 0.195860 0.395433 0.555276; 0.194100 0.399323 0.555565;
        0.192357 0.403199 0.555836; 0.190631 0.407061 0.556089; 0.188923 0.410910 0.556326; 0.187231 0.414746 0.556547;
        0.185556 0.418570 0.556753; 0.183898 0.422383 0.556944; 0.182256 0.426184 0.557120; 0.180629 0.429975 0.557282;
        0.179019 0.433756 0.557430; 0.177423 0.437527 0.557565; 0.175841 0.441290 0.557685; 0.174274 0.445044 0.557792;
        0.172719 0.448791 0.557885; 0.171176 0.452530 0.557965; 0.169646 0.456262 0.558030; 0.168126 0.459988 0.558082;
        0.166617 0.463708 0.558119; 0.165117 0.467423 0.558141; 0.163625 0.471133 0.558148; 0.162142 0.474838 0.558140;
        0.160665 0.478540 0.558115; 0.159194 0.482237 0.558073; 0.157729 0.485932 0.558013; 0.156270 0.489624 0.557936;
        0.154815 0.493313 0.557840; 0.153364 0.497000 0.557724; 0.151918 0.500685 0.557587; 0.150476 0.504369 0.557430;
        0.149039 0.508051 0.557250; 0.147607 0.511733 0.557049; 0.146180 0.515413 0.556823; 0.144759 0.519093 0.556572;
        0.143343 0.522773 0.556295; 0.141935 0.526453 0.555991; 0.140536 0.530132 0.555659; 0.139147 0.533812 0.555298;
        0.137770 0.537492 0.554906; 0.136408 0.541173 0.554483; 0.135066 0.544853 0.554029; 0.133743 0.548535 0.553541;
        0.132444 0.552216 0.553018; 0.131172 0.555899 0.552459; 0.129933 0.559582 0.551864; 0.128729 0.563265 0.551229;
        0.127568 0.566949 0.550556; 0.126453 0.570633 0.549841; 0.125394 0.574318 0.549086; 0.124395 0.578002 0.548287;
        0.123463 0.581687 0.547445; 0.122606 0.585371 0.546557; 0.121831 0.589055 0.545623; 0.121148 0.592739 0.544641;
        0.120565 0.596422 0.543611; 0.120092 0.600104 0.542530; 0.119738 0.603785 0.541400; 0.119512 0.607464 0.540218;
        0.119423 0.611141 0.538982; 0.119483 0.614817 0.537692; 0.119699 0.618490 0.536347; 0.120081 0.622161 0.534946;
        0.120638 0.625828 0.533488; 0.121380 0.629492 0.531973; 0.122312 0.633153 0.530398; 0.123444 0.636809 0.528763;
        0.124780 0.640461 0.527068; 0.126326 0.644107 0.525311; 0.128087 0.647749 0.523491; 0.130067 0.651384 0.521608;
        0.132268 0.655014 0.519661; 0.134692 0.658636 0.517649; 0.137339 0.662252 0.515571; 0.140210 0.665859 0.513427;
        0.143303 0.669459 0.511215; 0.146616 0.673050 0.508936; 0.150148 0.676631 0.506589; 0.153894 0.680203 0.504172;
        0.157851 0.683765 0.501686; 0.162016 0.687316 0.499129; 0.166383 0.690856 0.496502; 0.170948 0.694384 0.493803;
        0.175707 0.697900 0.491033; 0.180653 0.701402 0.488189; 0.185783 0.704891 0.485273; 0.191090 0.708366 0.482284;
        0.196571 0.711827 0.479221; 0.202219 0.715272 0.476084; 0.208030 0.718701 0.472873; 0.214000 0.722114 0.469588;
        0.220124 0.725509 0.466226; 0.226397 0.728888 0.462789; 0.232815 0.732247 0.459277; 0.239374 0.735588 0.455688;
        0.246070 0.738910 0.452024; 0.252899 0.742211 0.448284; 0.259857 0.745492 0.444467; 0.266941 0.748751 0.440573;
        0.274149 0.751988 0.436601; 0.281477 0.755203 0.432552; 0.288921 0.758394 0.428426; 0.296479 0.761561 0.424223;
        0.304148 0.764704 0.419943; 0.311925 0.767822 0.415586; 0.319809 0.770914 0.411152; 0.327796 0.773980 0.406640;
        0.335885 0.777018 0.402049; 0.344074 0.780029 0.397381; 0.352360 0.783011 0.392636; 0.360741 0.785964 0.387814;
        0.369214 0.788888 0.382914; 0.377779 0.791781 0.377939; 0.386433 0.794644 0.372886; 0.395174 0.797475 0.367757;
        0.404001 0.800275 0.362552; 0.412913 0.803041 0.357269; 0.421908 0.805774 0.351910; 0.430983 0.808473 0.346476;
        0.440137 0.811138 0.340967; 0.449368 0.813768 0.335384; 0.458674 0.816363 0.329727; 0.468053 0.818921 0.323998;
        0.477504 0.821444 0.318195; 0.487026 0.823929 0.312321; 0.496615 0.826376 0.306377; 0.506271 0.828786 0.300362;
        0.515992 0.831158 0.294279; 0.525776 0.833491 0.288127; 0.535621 0.835785 0.281908; 0.545524 0.838039 0.275626;
        0.555484 0.840254 0.269281; 0.565498 0.842430 0.262877; 0.575563 0.844566 0.256415; 0.585678 0.846661 0.249897;
        0.595839 0.848717 0.243329; 0.606045 0.850733 0.236712; 0.616293 0.852709 0.230052; 0.626579 0.854645 0.223353;
        0.636902 0.856542 0.216620; 0.647257 0.858400 0.209861; 0.657642 0.860219 0.203082; 0.668054 0.861999 0.196293;
        0.678489 0.863742 0.189503; 0.688944 0.865448 0.182725; 0.699415 0.867117 0.175971; 0.709898 0.868751 0.169257;
        0.720391 0.870350 0.162603; 0.730889 0.871916 0.156029; 0.741388 0.873449 0.149561; 0.751884 0.874951 0.143228;
        0.762373 0.876424 0.137064; 0.772852 0.877868 0.131109; 0.783315 0.879285 0.125405; 0.793760 0.880678 0.120005;
        0.804182 0.882046 0.114965; 0.814576 0.883393 0.110347; 0.824940 0.884720 0.106217; 0.835270 0.886029 0.102646;
        0.845561 0.887322 0.099702; 0.855810 0.888601 0.097452; 0.866013 0.889868 0.095953; 0.876168 0.891125 0.095250;
        0.886271 0.892374 0.095374; 0.896320 0.893616 0.096335; 0.906311 0.894855 0.098125; 0.916242 0.896091 0.100717;
        0.926106 0.897330 0.104071; 0.935904 0.898570 0.108131; 0.945636 0.899815 0.112838; 0.955300 0.901065 0.118128;
        0.964894 0.902323 0.123941; 0.974417 0.903590 0.130215; 0.983868 0.904867 0.136897; 0.993248 0.906157 0.143936;
        ];
    % viridis  sum=331.7005180000  row1=[0.267004 0.004874 0.329415]  row256=[0.993248 0.906157 0.143936]
    T.magma = [ ...
        0.001462 0.000466 0.013866; 0.002258 0.001295 0.018331; 0.003279 0.002305 0.023708; 0.004512 0.003490 0.029965;
        0.005950 0.004843 0.037130; 0.007588 0.006356 0.044973; 0.009426 0.008022 0.052844; 0.011465 0.009828 0.060750;
        0.013708 0.011771 0.068667; 0.016156 0.013840 0.076603; 0.018815 0.016026 0.084584; 0.021692 0.018320 0.092610;
        0.024792 0.020715 0.100676; 0.028123 0.023201 0.108787; 0.031696 0.025765 0.116965; 0.035520 0.028397 0.125209;
        0.039608 0.031090 0.133515; 0.043830 0.033830 0.141886; 0.048062 0.036607 0.150327; 0.052320 0.039407 0.158841;
        0.056615 0.042160 0.167446; 0.060949 0.044794 0.176129; 0.065330 0.047318 0.184892; 0.069764 0.049726 0.193735;
        0.074257 0.052017 0.202660; 0.078815 0.054184 0.211667; 0.083446 0.056225 0.220755; 0.088155 0.058133 0.229922;
        0.092949 0.059904 0.239164; 0.097833 0.061531 0.248477; 0.102815 0.063010 0.257854; 0.107899 0.064335 0.267289;
        0.113094 0.065492 0.276784; 0.118405 0.066479 0.286321; 0.123833 0.067295 0.295879; 0.129380 0.067935 0.305443;
        0.135053 0.068391 0.315000; 0.140858 0.068654 0.324538; 0.146785 0.068738 0.334011; 0.152839 0.068637 0.343404;
        0.159018 0.068354 0.352688; 0.165308 0.067911 0.361816; 0.171713 0.067305 0.370771; 0.178212 0.066576 0.379497;
        0.184801 0.065732 0.387973; 0.191460 0.064818 0.396152; 0.198177 0.063862 0.404009; 0.204935 0.062907 0.411514;
        0.211718 0.061992 0.418647; 0.218512 0.061158 0.425392; 0.225302 0.060445 0.431742; 0.232077 0.059889 0.437695;
        0.238826 0.059517 0.443256; 0.245543 0.059352 0.448436; 0.252220 0.059415 0.453248; 0.258857 0.059706 0.457710;
        0.265447 0.060237 0.461840; 0.271994 0.060994 0.465660; 0.278493 0.061978 0.469190; 0.284951 0.063168 0.472451;
        0.291366 0.064553 0.475462; 0.297740 0.066117 0.478243; 0.304081 0.067835 0.480812; 0.310382 0.069702 0.483186;
        0.316654 0.071690 0.485380; 0.322899 0.073782 0.487408; 0.329114 0.075972 0.489287; 0.335308 0.078236 0.491024;
        0.341482 0.080564 0.492631; 0.347636 0.082946 0.494121; 0.353773 0.085373 0.495501; 0.359898 0.087831 0.496778;
        0.366012 0.090314 0.497960; 0.372116 0.092816 0.499053; 0.378211 0.095332 0.500067; 0.384299 0.097855 0.501002;
        0.390384 0.100379 0.501864; 0.396467 0.102902 0.502658; 0.402548 0.105420 0.503386; 0.408629 0.107930 0.504052;
        0.414709 0.110431 0.504662; 0.420791 0.112920 0.505215; 0.426877 0.115395 0.505714; 0.432967 0.117855 0.506160;
        0.439062 0.120298 0.506555; 0.445163 0.122724 0.506901; 0.451271 0.125132 0.507198; 0.457386 0.127522 0.507448;
        0.463508 0.129893 0.507652; 0.469640 0.132245 0.507809; 0.475780 0.134577 0.507921; 0.481929 0.136891 0.507989;
        0.488088 0.139186 0.508011; 0.494258 0.141462 0.507988; 0.500438 0.143719 0.507920; 0.506629 0.145958 0.507806;
        0.512831 0.148179 0.507648; 0.519045 0.150383 0.507443; 0.525270 0.152569 0.507192; 0.531507 0.154739 0.506895;
        0.537755 0.156894 0.506551; 0.544015 0.159033 0.506159; 0.550287 0.161158 0.505719; 0.556571 0.163269 0.505230;
        0.562866 0.165368 0.504692; 0.569172 0.167454 0.504105; 0.575490 0.169530 0.503466; 0.581819 0.171596 0.502777;
        0.588158 0.173652 0.502035; 0.594508 0.175701 0.501241; 0.600868 0.177743 0.500394; 0.607238 0.179779 0.499492;
        0.613617 0.181811 0.498536; 0.620005 0.183840 0.497524; 0.626401 0.185867 0.496456; 0.632805 0.187893 0.495332;
        0.639216 0.189921 0.494150; 0.645633 0.191952 0.492910; 0.652056 0.193986 0.491611; 0.658483 0.196027 0.490253;
        0.664915 0.198075 0.488836; 0.671349 0.200133 0.487358; 0.677786 0.202203 0.485819; 0.684224 0.204286 0.484219;
        0.690661 0.206384 0.482558; 0.697098 0.208501 0.480835; 0.703532 0.210638 0.479049; 0.709962 0.212797 0.477201;
        0.716387 0.214982 0.475290; 0.722805 0.217194 0.473316; 0.729216 0.219437 0.471279; 0.735616 0.221713 0.469180;
        0.742004 0.224025 0.467018; 0.748378 0.226377 0.464794; 0.754737 0.228772 0.462509; 0.761077 0.231214 0.460162;
        0.767398 0.233705 0.457755; 0.773695 0.236249 0.455289; 0.779968 0.238851 0.452765; 0.786212 0.241514 0.450184;
        0.792427 0.244242 0.447543; 0.798608 0.247040 0.444848; 0.804752 0.249911 0.442102; 0.810855 0.252861 0.439305;
        0.816914 0.255895 0.436461; 0.822926 0.259016 0.433573; 0.828886 0.262229 0.430644; 0.834791 0.265540 0.427671;
        0.840636 0.268953 0.424666; 0.846416 0.272473 0.421631; 0.852126 0.276106 0.418573; 0.857763 0.279857 0.415496;
        0.863320 0.283729 0.412403; 0.868793 0.287728 0.409303; 0.874176 0.291859 0.406205; 0.879464 0.296125 0.403118;
        0.884651 0.300530 0.400047; 0.889731 0.305079 0.397002; 0.894700 0.309773 0.393995; 0.899552 0.314616 0.391037;
        0.904281 0.319610 0.388137; 0.908884 0.324755 0.385308; 0.913354 0.330052 0.382563; 0.917689 0.335500 0.379915;
        0.921884 0.341098 0.377376; 0.925937 0.346844 0.374959; 0.929845 0.352734 0.372677; 0.933606 0.358764 0.370541;
        0.937221 0.364929 0.368567; 0.940687 0.371224 0.366762; 0.944006 0.377643 0.365136; 0.947180 0.384178 0.363701;
        0.950210 0.390820 0.362468; 0.953099 0.397563 0.361438; 0.955849 0.404400 0.360619; 0.958464 0.411324 0.360014;
        0.960949 0.418323 0.359630; 0.963310 0.425390 0.359469; 0.965549 0.432519 0.359529; 0.967671 0.439703 0.359810;
        0.969680 0.446936 0.360311; 0.971582 0.454210 0.361030; 0.973381 0.461520 0.361965; 0.975082 0.468861 0.363111;
        0.976690 0.476226 0.364466; 0.978210 0.483612 0.366025; 0.979645 0.491014 0.367783; 0.981000 0.498428 0.369734;
        0.982279 0.505851 0.371874; 0.983485 0.513280 0.374198; 0.984622 0.520713 0.376698; 0.985693 0.528148 0.379371;
        0.986700 0.535582 0.382210; 0.987646 0.543015 0.385210; 0.988533 0.550446 0.388365; 0.989363 0.557873 0.391671;
        0.990138 0.565296 0.395122; 0.990871 0.572706 0.398714; 0.991558 0.580107 0.402441; 0.992196 0.587502 0.406299;
        0.992785 0.594891 0.410283; 0.993326 0.602275 0.414390; 0.993834 0.609644 0.418613; 0.994309 0.616999 0.422950;
        0.994738 0.624350 0.427397; 0.995122 0.631696 0.431951; 0.995480 0.639027 0.436607; 0.995810 0.646344 0.441361;
        0.996096 0.653659 0.446213; 0.996341 0.660969 0.451160; 0.996580 0.668256 0.456192; 0.996775 0.675541 0.461314;
        0.996925 0.682828 0.466526; 0.997077 0.690088 0.471811; 0.997186 0.697349 0.477182; 0.997254 0.704611 0.482635;
        0.997325 0.711848 0.488154; 0.997351 0.719089 0.493755; 0.997351 0.726324 0.499428; 0.997341 0.733545 0.505167;
        0.997285 0.740772 0.510983; 0.997228 0.747981 0.516859; 0.997138 0.755190 0.522806; 0.997019 0.762398 0.528821;
        0.996898 0.769591 0.534892; 0.996727 0.776795 0.541039; 0.996571 0.783977 0.547233; 0.996369 0.791167 0.553499;
        0.996162 0.798348 0.559820; 0.995932 0.805527 0.566202; 0.995680 0.812706 0.572645; 0.995424 0.819875 0.579140;
        0.995131 0.827052 0.585701; 0.994851 0.834213 0.592307; 0.994524 0.841387 0.598983; 0.994222 0.848540 0.605696;
        0.993866 0.855711 0.612482; 0.993545 0.862859 0.619299; 0.993170 0.870024 0.626189; 0.992831 0.877168 0.633109;
        0.992440 0.884330 0.640099; 0.992089 0.891470 0.647116; 0.991688 0.898627 0.654202; 0.991332 0.905763 0.661309;
        0.990930 0.912915 0.668481; 0.990570 0.920049 0.675675; 0.990175 0.927196 0.682926; 0.989815 0.934329 0.690198;
        0.989434 0.941470 0.697519; 0.989077 0.948604 0.704863; 0.988717 0.955742 0.712242; 0.988367 0.962878 0.719649;
        0.988033 0.970012 0.727077; 0.987691 0.977154 0.734536; 0.987387 0.984288 0.742002; 0.987053 0.991438 0.749504;
        ];
    % magma    sum=353.4014400000  row1=[0.001462 0.000466 0.013866]  row256=[0.987053 0.991438 0.749504]
    T.jet = [ ...
        0.000000 0.000000 0.500000; 0.000000 0.000000 0.517825; 0.000000 0.000000 0.535651; 0.000000 0.000000 0.553476;
        0.000000 0.000000 0.571301; 0.000000 0.000000 0.589127; 0.000000 0.000000 0.606952; 0.000000 0.000000 0.624777;
        0.000000 0.000000 0.642602; 0.000000 0.000000 0.660428; 0.000000 0.000000 0.678253; 0.000000 0.000000 0.696078;
        0.000000 0.000000 0.713904; 0.000000 0.000000 0.731729; 0.000000 0.000000 0.749554; 0.000000 0.000000 0.767380;
        0.000000 0.000000 0.785205; 0.000000 0.000000 0.803030; 0.000000 0.000000 0.820856; 0.000000 0.000000 0.838681;
        0.000000 0.000000 0.856506; 0.000000 0.000000 0.874332; 0.000000 0.000000 0.892157; 0.000000 0.000000 0.909982;
        0.000000 0.000000 0.927807; 0.000000 0.000000 0.945633; 0.000000 0.000000 0.963458; 0.000000 0.000000 0.981283;
        0.000000 0.000000 0.999109; 0.000000 0.000000 1.000000; 0.000000 0.000000 1.000000; 0.000000 0.000000 1.000000;
        0.000000 0.001961 1.000000; 0.000000 0.017647 1.000000; 0.000000 0.033333 1.000000; 0.000000 0.049020 1.000000;
        0.000000 0.064706 1.000000; 0.000000 0.080392 1.000000; 0.000000 0.096078 1.000000; 0.000000 0.111765 1.000000;
        0.000000 0.127451 1.000000; 0.000000 0.143137 1.000000; 0.000000 0.158824 1.000000; 0.000000 0.174510 1.000000;
        0.000000 0.190196 1.000000; 0.000000 0.205882 1.000000; 0.000000 0.221569 1.000000; 0.000000 0.237255 1.000000;
        0.000000 0.252941 1.000000; 0.000000 0.268627 1.000000; 0.000000 0.284314 1.000000; 0.000000 0.300000 1.000000;
        0.000000 0.315686 1.000000; 0.000000 0.331373 1.000000; 0.000000 0.347059 1.000000; 0.000000 0.362745 1.000000;
        0.000000 0.378431 1.000000; 0.000000 0.394118 1.000000; 0.000000 0.409804 1.000000; 0.000000 0.425490 1.000000;
        0.000000 0.441176 1.000000; 0.000000 0.456863 1.000000; 0.000000 0.472549 1.000000; 0.000000 0.488235 1.000000;
        0.000000 0.503922 1.000000; 0.000000 0.519608 1.000000; 0.000000 0.535294 1.000000; 0.000000 0.550980 1.000000;
        0.000000 0.566667 1.000000; 0.000000 0.582353 1.000000; 0.000000 0.598039 1.000000; 0.000000 0.613725 1.000000;
        0.000000 0.629412 1.000000; 0.000000 0.645098 1.000000; 0.000000 0.660784 1.000000; 0.000000 0.676471 1.000000;
        0.000000 0.692157 1.000000; 0.000000 0.707843 1.000000; 0.000000 0.723529 1.000000; 0.000000 0.739216 1.000000;
        0.000000 0.754902 1.000000; 0.000000 0.770588 1.000000; 0.000000 0.786275 1.000000; 0.000000 0.801961 1.000000;
        0.000000 0.817647 1.000000; 0.000000 0.833333 1.000000; 0.000000 0.849020 1.000000; 0.000000 0.864706 0.996205;
        0.000000 0.880392 0.983555; 0.000000 0.896078 0.970904; 0.009488 0.911765 0.958254; 0.022138 0.927451 0.945604;
        0.034788 0.943137 0.932954; 0.047438 0.958824 0.920304; 0.060089 0.974510 0.907653; 0.072739 0.990196 0.895003;
        0.085389 1.000000 0.882353; 0.098039 1.000000 0.869703; 0.110689 1.000000 0.857052; 0.123340 1.000000 0.844402;
        0.135990 1.000000 0.831752; 0.148640 1.000000 0.819102; 0.161290 1.000000 0.806452; 0.173941 1.000000 0.793801;
        0.186591 1.000000 0.781151; 0.199241 1.000000 0.768501; 0.211891 1.000000 0.755851; 0.224541 1.000000 0.743201;
        0.237192 1.000000 0.730550; 0.249842 1.000000 0.717900; 0.262492 1.000000 0.705250; 0.275142 1.000000 0.692600;
        0.287793 1.000000 0.679949; 0.300443 1.000000 0.667299; 0.313093 1.000000 0.654649; 0.325743 1.000000 0.641999;
        0.338393 1.000000 0.629349; 0.351044 1.000000 0.616698; 0.363694 1.000000 0.604048; 0.376344 1.000000 0.591398;
        0.388994 1.000000 0.578748; 0.401645 1.000000 0.566097; 0.414295 1.000000 0.553447; 0.426945 1.000000 0.540797;
        0.439595 1.000000 0.528147; 0.452245 1.000000 0.515497; 0.464896 1.000000 0.502846; 0.477546 1.000000 0.490196;
        0.490196 1.000000 0.477546; 0.502846 1.000000 0.464896; 0.515497 1.000000 0.452245; 0.528147 1.000000 0.439595;
        0.540797 1.000000 0.426945; 0.553447 1.000000 0.414295; 0.566097 1.000000 0.401645; 0.578748 1.000000 0.388994;
        0.591398 1.000000 0.376344; 0.604048 1.000000 0.363694; 0.616698 1.000000 0.351044; 0.629349 1.000000 0.338393;
        0.641999 1.000000 0.325743; 0.654649 1.000000 0.313093; 0.667299 1.000000 0.300443; 0.679949 1.000000 0.287793;
        0.692600 1.000000 0.275142; 0.705250 1.000000 0.262492; 0.717900 1.000000 0.249842; 0.730550 1.000000 0.237192;
        0.743201 1.000000 0.224541; 0.755851 1.000000 0.211891; 0.768501 1.000000 0.199241; 0.781151 1.000000 0.186591;
        0.793801 1.000000 0.173941; 0.806452 1.000000 0.161290; 0.819102 1.000000 0.148640; 0.831752 1.000000 0.135990;
        0.844402 1.000000 0.123340; 0.857052 1.000000 0.110689; 0.869703 1.000000 0.098039; 0.882353 1.000000 0.085389;
        0.895003 1.000000 0.072739; 0.907653 1.000000 0.060089; 0.920304 1.000000 0.047438; 0.932954 1.000000 0.034788;
        0.945604 0.988381 0.022138; 0.958254 0.973856 0.009488; 0.970904 0.959332 0.000000; 0.983555 0.944808 0.000000;
        0.996205 0.930283 0.000000; 1.000000 0.915759 0.000000; 1.000000 0.901235 0.000000; 1.000000 0.886710 0.000000;
        1.000000 0.872186 0.000000; 1.000000 0.857662 0.000000; 1.000000 0.843137 0.000000; 1.000000 0.828613 0.000000;
        1.000000 0.814089 0.000000; 1.000000 0.799564 0.000000; 1.000000 0.785040 0.000000; 1.000000 0.770516 0.000000;
        1.000000 0.755991 0.000000; 1.000000 0.741467 0.000000; 1.000000 0.726943 0.000000; 1.000000 0.712418 0.000000;
        1.000000 0.697894 0.000000; 1.000000 0.683370 0.000000; 1.000000 0.668845 0.000000; 1.000000 0.654321 0.000000;
        1.000000 0.639797 0.000000; 1.000000 0.625272 0.000000; 1.000000 0.610748 0.000000; 1.000000 0.596224 0.000000;
        1.000000 0.581699 0.000000; 1.000000 0.567175 0.000000; 1.000000 0.552651 0.000000; 1.000000 0.538126 0.000000;
        1.000000 0.523602 0.000000; 1.000000 0.509078 0.000000; 1.000000 0.494553 0.000000; 1.000000 0.480029 0.000000;
        1.000000 0.465505 0.000000; 1.000000 0.450980 0.000000; 1.000000 0.436456 0.000000; 1.000000 0.421932 0.000000;
        1.000000 0.407407 0.000000; 1.000000 0.392883 0.000000; 1.000000 0.378359 0.000000; 1.000000 0.363834 0.000000;
        1.000000 0.349310 0.000000; 1.000000 0.334786 0.000000; 1.000000 0.320261 0.000000; 1.000000 0.305737 0.000000;
        1.000000 0.291213 0.000000; 1.000000 0.276688 0.000000; 1.000000 0.262164 0.000000; 1.000000 0.247640 0.000000;
        1.000000 0.233115 0.000000; 1.000000 0.218591 0.000000; 1.000000 0.204067 0.000000; 1.000000 0.189542 0.000000;
        1.000000 0.175018 0.000000; 1.000000 0.160494 0.000000; 1.000000 0.145969 0.000000; 1.000000 0.131445 0.000000;
        1.000000 0.116921 0.000000; 1.000000 0.102397 0.000000; 1.000000 0.087872 0.000000; 0.999109 0.073348 0.000000;
        0.981283 0.058824 0.000000; 0.963458 0.044299 0.000000; 0.945633 0.029775 0.000000; 0.927807 0.015251 0.000000;
        0.909982 0.000726 0.000000; 0.892157 0.000000 0.000000; 0.874332 0.000000 0.000000; 0.856506 0.000000 0.000000;
        0.838681 0.000000 0.000000; 0.820856 0.000000 0.000000; 0.803030 0.000000 0.000000; 0.785205 0.000000 0.000000;
        0.767380 0.000000 0.000000; 0.749554 0.000000 0.000000; 0.731729 0.000000 0.000000; 0.713904 0.000000 0.000000;
        0.696078 0.000000 0.000000; 0.678253 0.000000 0.000000; 0.660428 0.000000 0.000000; 0.642602 0.000000 0.000000;
        0.624777 0.000000 0.000000; 0.606952 0.000000 0.000000; 0.589127 0.000000 0.000000; 0.571301 0.000000 0.000000;
        0.553476 0.000000 0.000000; 0.535651 0.000000 0.000000; 0.517825 0.000000 0.000000; 0.500000 0.000000 0.000000;
        ];
    % jet      sum=372.7970712821  row1=[0.000000 0.000000 0.500000]  row256=[0.500000 0.000000 0.000000]
    T.RdBu_r = [ ...
        0.019608 0.188235 0.380392; 0.023914 0.196540 0.391926; 0.028220 0.204844 0.403460; 0.032526 0.213149 0.414994;
        0.036832 0.221453 0.426528; 0.041138 0.229758 0.438062; 0.045444 0.238062 0.449596; 0.049750 0.246367 0.461130;
        0.054056 0.254671 0.472664; 0.058362 0.262976 0.484198; 0.062668 0.271280 0.495732; 0.066974 0.279585 0.507266;
        0.071280 0.287889 0.518800; 0.075586 0.296194 0.530334; 0.079892 0.304498 0.541869; 0.084198 0.312803 0.553403;
        0.088504 0.321107 0.564937; 0.092810 0.329412 0.576471; 0.097116 0.337716 0.588005; 0.101423 0.346021 0.599539;
        0.105729 0.354325 0.611073; 0.110035 0.362630 0.622607; 0.114341 0.370934 0.634141; 0.118647 0.379239 0.645675;
        0.122953 0.387543 0.657209; 0.127259 0.395848 0.668743; 0.132026 0.403460 0.676278; 0.137255 0.410381 0.679815;
        0.142484 0.417301 0.683353; 0.147712 0.424221 0.686890; 0.152941 0.431142 0.690427; 0.158170 0.438062 0.693964;
        0.163399 0.444983 0.697501; 0.168627 0.451903 0.701038; 0.173856 0.458824 0.704575; 0.179085 0.465744 0.708112;
        0.184314 0.472664 0.711649; 0.189542 0.479585 0.715186; 0.194771 0.486505 0.718724; 0.200000 0.493426 0.722261;
        0.205229 0.500346 0.725798; 0.210458 0.507266 0.729335; 0.215686 0.514187 0.732872; 0.220915 0.521107 0.736409;
        0.226144 0.528028 0.739946; 0.231373 0.534948 0.743483; 0.236601 0.541869 0.747020; 0.241830 0.548789 0.750557;
        0.247059 0.555709 0.754095; 0.252288 0.562630 0.757632; 0.257516 0.569550 0.761169; 0.262745 0.576471 0.764706;
        0.274894 0.584160 0.768858; 0.287043 0.591849 0.773010; 0.299193 0.599539 0.777163; 0.311342 0.607228 0.781315;
        0.323491 0.614917 0.785467; 0.335640 0.622607 0.789619; 0.347789 0.630296 0.793772; 0.359938 0.637985 0.797924;
        0.372088 0.645675 0.802076; 0.384237 0.653364 0.806228; 0.396386 0.661053 0.810381; 0.408535 0.668743 0.814533;
        0.420684 0.676432 0.818685; 0.432834 0.684121 0.822837; 0.444983 0.691811 0.826990; 0.457132 0.699500 0.831142;
        0.469281 0.707190 0.835294; 0.481430 0.714879 0.839446; 0.493579 0.722568 0.843599; 0.505729 0.730258 0.847751;
        0.517878 0.737947 0.851903; 0.530027 0.745636 0.856055; 0.542176 0.753326 0.860208; 0.554325 0.761015 0.864360;
        0.566474 0.768704 0.868512; 0.577393 0.775010 0.871972; 0.587082 0.779931 0.874740; 0.596770 0.784852 0.877509;
        0.606459 0.789773 0.880277; 0.616148 0.794694 0.883045; 0.625836 0.799616 0.885813; 0.635525 0.804537 0.888581;
        0.645213 0.809458 0.891349; 0.654902 0.814379 0.894118; 0.664591 0.819300 0.896886; 0.674279 0.824221 0.899654;
        0.683968 0.829143 0.902422; 0.693656 0.834064 0.905190; 0.703345 0.838985 0.907958; 0.713033 0.843906 0.910727;
        0.722722 0.848827 0.913495; 0.732411 0.853749 0.916263; 0.742099 0.858670 0.919031; 0.751788 0.863591 0.921799;
        0.761476 0.868512 0.924567; 0.771165 0.873433 0.927336; 0.780854 0.878354 0.930104; 0.790542 0.883276 0.932872;
        0.800231 0.888197 0.935640; 0.809919 0.893118 0.938408; 0.819608 0.898039 0.941176; 0.825452 0.900807 0.942253;
        0.831296 0.903576 0.943329; 0.837140 0.906344 0.944406; 0.842983 0.909112 0.945483; 0.848827 0.911880 0.946559;
        0.854671 0.914648 0.947636; 0.860515 0.917416 0.948712; 0.866359 0.920185 0.949789; 0.872203 0.922953 0.950865;
        0.878047 0.925721 0.951942; 0.883891 0.928489 0.953018; 0.889735 0.931257 0.954095; 0.895579 0.934025 0.955171;
        0.901423 0.936794 0.956248; 0.907266 0.939562 0.957324; 0.913110 0.942330 0.958401; 0.918954 0.945098 0.959477;
        0.924798 0.947866 0.960554; 0.930642 0.950634 0.961630; 0.936486 0.953403 0.962707; 0.942330 0.956171 0.963783;
        0.948174 0.958939 0.964860; 0.954018 0.961707 0.965936; 0.959862 0.964475 0.967013; 0.965705 0.967243 0.968089;
        0.969089 0.966474 0.964937; 0.970012 0.962168 0.957555; 0.970934 0.957862 0.950173; 0.971857 0.953556 0.942791;
        0.972780 0.949250 0.935409; 0.973702 0.944944 0.928028; 0.974625 0.940638 0.920646; 0.975548 0.936332 0.913264;
        0.976471 0.932026 0.905882; 0.977393 0.927720 0.898501; 0.978316 0.923414 0.891119; 0.979239 0.919108 0.883737;
        0.980161 0.914802 0.876355; 0.981084 0.910496 0.868973; 0.982007 0.906190 0.861592; 0.982930 0.901884 0.854210;
        0.983852 0.897578 0.846828; 0.984775 0.893272 0.839446; 0.985698 0.888966 0.832065; 0.986621 0.884660 0.824683;
        0.987543 0.880354 0.817301; 0.988466 0.876048 0.809919; 0.989389 0.871742 0.802537; 0.990311 0.867436 0.795156;
        0.991234 0.863130 0.787774; 0.992157 0.858824 0.780392; 0.990773 0.850519 0.769781; 0.989389 0.842215 0.759170;
        0.988005 0.833910 0.748558; 0.986621 0.825606 0.737947; 0.985236 0.817301 0.727336; 0.983852 0.808997 0.716724;
        0.982468 0.800692 0.706113; 0.981084 0.792388 0.695502; 0.979700 0.784083 0.684890; 0.978316 0.775779 0.674279;
        0.976932 0.767474 0.663668; 0.975548 0.759170 0.653057; 0.974164 0.750865 0.642445; 0.972780 0.742561 0.631834;
        0.971396 0.734256 0.621223; 0.970012 0.725952 0.610611; 0.968627 0.717647 0.600000; 0.967243 0.709343 0.589389;
        0.965859 0.701038 0.578777; 0.964475 0.692734 0.568166; 0.963091 0.684429 0.557555; 0.961707 0.676125 0.546943;
        0.960323 0.667820 0.536332; 0.958939 0.659516 0.525721; 0.957555 0.651211 0.515110; 0.954556 0.641753 0.505729;
        0.949942 0.631142 0.497578; 0.945329 0.620531 0.489427; 0.940715 0.609919 0.481276; 0.936101 0.599308 0.473126;
        0.931488 0.588697 0.464975; 0.926874 0.578085 0.456824; 0.922261 0.567474 0.448674; 0.917647 0.556863 0.440523;
        0.913033 0.546251 0.432372; 0.908420 0.535640 0.424221; 0.903806 0.525029 0.416071; 0.899193 0.514418 0.407920;
        0.894579 0.503806 0.399769; 0.889965 0.493195 0.391619; 0.885352 0.482584 0.383468; 0.880738 0.471972 0.375317;
        0.876125 0.461361 0.367166; 0.871511 0.450750 0.359016; 0.866897 0.440138 0.350865; 0.862284 0.429527 0.342714;
        0.857670 0.418916 0.334564; 0.853057 0.408304 0.326413; 0.848443 0.397693 0.318262; 0.843829 0.387082 0.310111;
        0.839216 0.376471 0.301961; 0.833679 0.365398 0.296732; 0.828143 0.354325 0.291503; 0.822607 0.343253 0.286275;
        0.817070 0.332180 0.281046; 0.811534 0.321107 0.275817; 0.805998 0.310035 0.270588; 0.800461 0.298962 0.265359;
        0.794925 0.287889 0.260131; 0.789389 0.276817 0.254902; 0.783852 0.265744 0.249673; 0.778316 0.254671 0.244444;
        0.772780 0.243599 0.239216; 0.767243 0.232526 0.233987; 0.761707 0.221453 0.228758; 0.756171 0.210381 0.223529;
        0.750634 0.199308 0.218301; 0.745098 0.188235 0.213072; 0.739562 0.177163 0.207843; 0.734025 0.166090 0.202614;
        0.728489 0.155017 0.197386; 0.722953 0.143945 0.192157; 0.717416 0.132872 0.186928; 0.711880 0.121799 0.181699;
        0.706344 0.110727 0.176471; 0.700807 0.099654 0.171242; 0.692272 0.092272 0.167705; 0.680738 0.088581 0.165859;
        0.669204 0.084890 0.164014; 0.657670 0.081200 0.162168; 0.646136 0.077509 0.160323; 0.634602 0.073818 0.158478;
        0.623068 0.070127 0.156632; 0.611534 0.066436 0.154787; 0.600000 0.062745 0.152941; 0.588466 0.059054 0.151096;
        0.576932 0.055363 0.149250; 0.565398 0.051672 0.147405; 0.553864 0.047982 0.145559; 0.542330 0.044291 0.143714;
        0.530796 0.040600 0.141869; 0.519262 0.036909 0.140023; 0.507728 0.033218 0.138178; 0.496194 0.029527 0.136332;
        0.484660 0.025836 0.134487; 0.473126 0.022145 0.132641; 0.461592 0.018454 0.130796; 0.450058 0.014764 0.128950;
        0.438524 0.011073 0.127105; 0.426990 0.007382 0.125260; 0.415456 0.003691 0.123414; 0.403922 0.000000 0.121569;
        ];
    % RdBu_r   sum=468.9526336025  row1=[0.019608 0.188235 0.380392]  row256=[0.403922 0.000000 0.121569]
end
key = char(name);
if ~isfield(T, key)
    error('drm2d:badCmap', 'Unknown colormap "%s".', key);
end
cmap = T.(key);
end


%% ========================================================== INFORMATION BOX

function [R0_mm, excess_mm, deficit_mm] = depthWindows(P, ddd, rng)
%DEPTHWINDOWS  Residual range behind the air gap and the two spectral blocks'
%   depth windows [mm].  Level k peaks at z = R0 - k, so the retained block
%   (k <= K_lo) covers the thinner zone's own SOBP and the removed block
%   (K_lo < k <= K_hi) covers the window only the thicker zone can reach.
lp    = levelProps(P, 'rashi', rng);
R0_mm = dddPeakDepth(ddd) - lp.airWepl_mm;
[KA, KB] = zoneLevels(P);
K_lo = min(KA, KB);  K_hi = max(KA, KB);
excess_mm  = [R0_mm - K_lo, R0_mm];
deficit_mm = [R0_mm - K_hi, R0_mm - K_lo];
end


function [refA_Gy, refB_Gy, ref_Gy] = perZoneRef(S, P)
%PERZONEREF  Local zone plateau dose [Gy]: the max RaShi dose inside each zone.
%   ref_Gy is a per-y-column vector so a map can be normalised zone by zone.
refA_Gy = NaN;  refB_Gy = NaN;  ref_Gy = [];
if isempty(S.dose.rashi_Gy), return; end
xe = S.dose.xEdges_mm;  ye = S.dose.yEdges_mm;
xc = 0.5*(xe(1:end-1) + xe(2:end));
yc = 0.5*(ye(1:end-1) + ye(2:end));
mx = abs(xc) <= P.fieldX_mm/2;
R  = S.dose.rashi_Gy;
inA = yc < 0 & abs(yc) <= P.widthA_mm;
inB = yc > 0 & abs(yc) <= P.widthB_mm;
if any(inA), sub = R(:, mx, inA);  refA_Gy = max(sub(:)); end
if any(inB), sub = R(:, mx, inB);  refB_Gy = max(sub(:)); end
ref_Gy = zeros(size(yc));
ref_Gy(yc <  0) = refA_Gy;
ref_Gy(yc >= 0) = refB_Gy;
ref_Gy(~isfinite(ref_Gy) | ref_Gy <= 0) = NaN;
end


function [DrefA, DrefB] = zoneReference(R, xc, yc, zc, P, R0)
%ZONEREFERENCE  (Dref_A, Dref_B): MEDIAN RaShi dose in each zone core, inside
%   that zone's own SOBP window [R0 - K + 10, R0 - 10].  Falls back to the
%   window max (i.e. the whole SOBP-and-up window) if it is too thin.
%   Ports validate_nonlocality.zone_reference (PLAN3.md section 3, P3) -- NOT
%   the same quantity as perZoneRef above (which is the window MAX, kept
%   because the GUI info box and T54 depend on its value).  Used only by
%   figMapsYZ's normalisation and the non-locality metrics.
[KA, KB] = zoneLevels(P);
specs = {KA, -10.5, -4.5; KB, 4.5, 10.5};
out = nan(1, 2);
nz = numel(zc);  nx = numel(xc);  ny = numel(yc);
for i = 1:2
    K  = specs{i,1};  lo = specs{i,2};  hi = specs{i,3};
    zw = (zc(:) > R0 - K*P.step_wepl_mm + 10) & (zc(:) < R0 - 10);
    if sum(zw) < 3
        zw = (zc(:) > R0 - K*P.step_wepl_mm) & (zc(:) < R0);
    end
    xm = abs(xc(:)') < 9;
    ym = (yc(:)' > lo) & (yc(:)' < hi);
    M  = reshape(zw, nz, 1, 1) & reshape(xm, 1, nx, 1) & reshape(ym, 1, 1, ny);
    if any(M(:)), out(i) = median(R(M)); end
end
DrefA = out(1);  DrefB = out(2);
end


function c = contrastPy(P, y_eval)
%CONTRASTPY  Closed-form non-locality contrast at a zone B cell (default the
%   first one, y = D/2).  Ports nonlocality.contrast (PLAN3.md section 3, P3).
%   f_A is the only FWHM-dependent quantity; (K_A-K_B)/K_B is the plan contrast.
if nargin < 2 || isempty(y_eval), y_eval = P.spacing_mm / 2; end
[KA, KB] = zoneLevels(P);
[~, fA]  = fZoneA(P, y_eval);
c = struct('y_mm', y_eval, 'f_A', fA, 'K_A', KA, 'K_B', KB, 'dK', KA - KB, ...
           'r_B', fA * (KA - KB) / KB, 'deficit_B', -fA, ...
           'r_A', (1 - fA) * KB / KA, 'deficit_A', -(1 - fA) * (KA - KB) / KA);
end


function pct = perZonePeakPct(S, P)
%PERZONEPEAKPCT  Peak |dD| as a percentage of the LOCAL zone plateau dose.
%   Shown next to the user's global-max figure because max(rashi) is a Region A
%   quantity: normalising a thin Region B against it shrinks the number
%   artificially (this is what produced the misleading turn-over at K_B = 10).
pct = NaN;
if isempty(S.dose.diff_pct) || isempty(S.dose.rashi_Gy), return; end
[~, ~, ref] = perZoneRef(S, P);
if isempty(ref) || all(isnan(ref)), return; end
dGy = S.dose.diff_pct / 100 * max(S.dose.rashi_Gy(:));     % back to Gy
rel = abs(dGy) ./ reshape(ref, 1, 1, []);
pct = max(rel(isfinite(rel))) * 100;
if isempty(pct), pct = NaN; end
end


function rms_pct = pinRippleRms(S, P)
%PINRIPPLERMS  RMS of the EXACT 2DRM difference about its pin-cell average [%].
%   The intra-cell level/position correlation that approximation A1 discards.
%   It has the pin period and vanishes under cell averaging, so it is measured
%   as (voxel value - cell-block mean) over the high-dose voxels.
%
%   It MUST be measured on (exact - rashi): that is the only array built from a
%   position-labelled fluence, and so the only one that carries the ripple.  The
%   displayed difference (local + nl - rashi) carries almost none by
%   construction -- local and rashi share an identical fluence (identity P1), so
%   their difference is the smooth material term, and nl is the cell-averaged
%   model, piecewise constant per pin cell.  Measuring it there returned a
%   DISCRETISATION ARTEFACT that collapsed 9x when the grid was refined
%   (0.466 % -> 0.054 %), whereas the real ripple is grid-independent
%   (0.941 % -> 0.931 %), as a physical quantity must be (defect D2).
%
%   NOTE: ~0.93 % is what this tool measures on this geometry.  It does NOT
%   reproduce the ~1.35 % quoted elsewhere in the project, which comes from the
%   Python model at its own settings and metric mask; that gap is unreconciled.
%
%   Returns NaN (displayed as "-") unless a CURRENT exact dose exists, rather
%   than falling back to a number that is not the ripple.
rms_pct = NaN;
if ~exactIsCurrent(S) || isempty(S.dose.rashi_Gy), return; end
f = round(P.spacing_mm / P.voxel_mm);
if f < 2, return; end
R = S.dose.rashi_Gy;
D = (S.dose.exact_Gy - R) / max(R(:)) * 100;      % [% of max RaShi dose]
[nz, nx, ny] = size(D);
nx2 = nx - mod(nx, f);  ny2 = ny - mod(ny, f);
if nx2 < f || ny2 < f, return; end
D = D(:, 1:nx2, 1:ny2);  R = R(:, 1:nx2, 1:ny2);
cell = blockMean3(D, f);                        % (nz, nx2/f, ny2/f)
cell = repelem(cell, 1, f, f);                  % back to voxel resolution
res  = D - cell;
m    = R > 0.5 * max(R(:));
if ~any(m(:)), return; end
rms_pct = sqrt(mean(res(m).^2));
end


function rms_pct = localRippleOf(D, R, f)
%LOCALRIPPLEOF  Test helper: ripple rms of a given percentage map D about its
%   pin-cell block mean, over the high-dose voxels of R.  Lets the selftest run
%   the SAME arithmetic on the pre-fix input (diff_pct) and the post-fix one
%   (exact - rashi), so T58 demonstrates that the INPUT changed rather than the
%   formula.  Not used by the GUI.
rms_pct = NaN;
if isempty(D) || isempty(R) || f < 2, return; end
[~, nx, ny] = size(D);
nx2 = nx - mod(nx, f);  ny2 = ny - mod(ny, f);
if nx2 < f || ny2 < f, return; end
D = D(:, 1:nx2, 1:ny2);  R = R(:, 1:nx2, 1:ny2);
res = D - repelem(blockMean3(D, f), 1, f, f);
m   = R > 0.5 * max(R(:));
if ~any(m(:)), return; end
rms_pct = sqrt(mean(res(m).^2));
end


function pct = modelVsExactPct(S)
%MODELVSEXACTPCT  max|exact - (local + dD)| / max(rashi) * 100.
%   The residual the closed-form model does NOT capture: pin ripple plus the
%   level-0 edge term (ions that miss the device entirely, F_R(0) = 0 but
%   F_M(0) ~= 0 outside the pinned area).  This is PLAN2 test T40's quantity.
pct = NaN;
if ~exactIsCurrent(S) || isempty(S.dose.after_Gy) || isempty(S.dose.rashi_Gy)
    return;                      % absent OR stale -> report "-" , never a number
end
d   = S.dose.exact_Gy - S.dose.after_Gy;
pct = max(abs(d(:))) / max(S.dose.rashi_Gy(:)) * 100;
end


function updateInfoBox(fig)
%UPDATEINFOBOX  Multi-line monospace readout (PLAN2.md section 4).
%   MODEL block depends on the parameters only and updates on every change;
%   the DOSE block fills in as the buttons are pressed.  Unset fields show "-".
S = guidata(fig);
if ~isfield(S.h, 'txt_info') || ~ishandle(S.h.txt_info), return; end
P = S.P;
L = {};

% ---------------- MODEL (parameters only) ----------------
try
    [KA, KB] = zoneLevels(P);
    dK   = KA - KB;
    sig  = P.fwhm0_mm * FWHM2SIG();                       % [mm]
    ctr  = contrastPy(P, P.spacing_mm/2);                 % at the first B cell
    fA   = ctr.f_A;
    if KB > 0, rB = ctr.r_B; else, rB = NaN; end
    a    = spectralWeight(P);
    sa   = sum(a);
    if abs(sa) < 1e-9, flag = 'OK'; else, flag = 'FAIL'; end
    L{end+1} = 'MODEL';
    L{end+1} = sprintf('  f_A (y=+D/2)      %.4f',       fA);
    L{end+1} = sprintf('  r_B = f_A dK/K_B  %.4f  (%.2f %%)', rB, rB*100);
    L{end+1} = sprintf('  sigma at device   %.3f mm',    sig);
    L{end+1} = sprintf('  sigma / pin pitch %.4f',       sig / P.spacing_mm);
    L{end+1} = sprintf('  sum(a_k)          %.2e  %s',   sa, flag);
catch err
    L{end+1} = 'MODEL';
    L{end+1} = sprintf('  (unavailable: %s)', err.message);
end

% ---------------- DOSE ----------------
L{end+1} = 'DOSE';
if ~isempty(S.dose.rashi_Gy)
    L{end+1} = sprintf('  max RaShi         %.5f Gy', max(S.dose.rashi_Gy(:)));
else
    L{end+1} = '  max RaShi         -';
end
if ~isempty(S.dose.local_Gy)
    L{end+1} = sprintf('  max 2DRM (local)  %.5f Gy', max(S.dose.local_Gy(:)));
else
    L{end+1} = '  max 2DRM (local)  -';
end
if ~isempty(S.dose.diff_pct)
    D = S.dose.diff_pct;
    [~, i] = max(abs(D(:)));
    [iz, ~, iy] = ind2sub(size(D), i);
    zc = 0.5*(S.dose.zEdges_mm(1:end-1) + S.dose.zEdges_mm(2:end));
    yc = 0.5*(S.dose.yEdges_mm(1:end-1) + S.dose.yEdges_mm(2:end));
    L{end+1} = sprintf('  peak |dD|         %.2f %% of max RaShi', abs(D(i)));
    L{end+1} = sprintf('    at y=%+.1f z=%.1f mm  (%s)', yc(iy), zc(iz), S.dose.diffMode);
    pz = perZonePeakPct(S, P);
    if isfinite(pz)
        L{end+1} = sprintf('    per-zone norm   %.2f %% of zone plateau', pz);
    else
        L{end+1} = '    per-zone norm   -';
    end
else
    L{end+1} = '  peak |dD|         -';
end
% Ripple needs a CURRENT exact dose, not the Apply state: it lives only in the
% position-labelled difference (see pinRippleRms).  Always shown, "-" when the
% exact dose is absent or stale, so the field never silently disappears.
rr = pinRippleRms(S, P);
if isfinite(rr)
    L{end+1} = sprintf('  pin ripple rms    %.2f %%', rr);
else
    L{end+1} = '  pin ripple rms    -  (tick Compare exact)';
end
mv = modelVsExactPct(S);
if isfinite(mv)
    L{end+1} = sprintf('  model vs exact    %.2f %%', mv);
else
    L{end+1} = '  model vs exact    -  (tick Compare exact)';
end
if isfield(S.dose, 'nlGridMismatch') && S.dose.nlGridMismatch
    L{end+1} = '!! nl grid mismatch - see DEFECTS.md (DEFECT-3/DEFECT-4)';
end

set(S.h.txt_info, 'String', L);
end


%% ============================================================ RESULT FIGURES

function keys = resultFigureKeys()
%RESULTFIGUREKEYS  The 11 figure keys, in Python-name order (PLAN3.md section 6).
%   Shared by the listbox (buildGui), the 'result' API and btn_savefigs.
keys = {'fig1_geometry', 'fig2_level_spectrum', 'fig3_dose_maps_yz', ...
        'fig4_depth_dose', 'fig5_lateral_profiles', 'fig6_scatter_sigma', ...
        'fig7_dD_xy', 'fig8_geometry_3d', ...
        'nl_fig1_mechanism', 'nl_fig2_delta_phi', 'nl_fig3_maps'};
end


function H = onResult(fig, keys)
%ONRESULT  Button 5.  Pop-up figures from the CURRENT GUI parameters.
%   PLAN3.md section 6.4: grown from 6 to 11 figures (the full
%   analysis.py + figs_nonlocality.py set, less the two dropped aggregates
%   fig4_profiles_FWHM6 / fig5_scaling -- see PLAN3.md section 2.3).
%   `keys` (optional): cell array of keys from resultFigureKeys() to build --
%   defaults to the GUI listbox selection, or all 11 when there is no
%   listbox (e.g. a figure handle built without buildGui).  Generates every
%   requested figure whose precondition is met and prints one named reason
%   per skipped figure ("generate what is possible, skip the rest", PLAN2
%   section 5).
S   = guidata(fig);
P   = S.P;
vis = get(fig, 'Visible');          % headless stays headless
H   = gobjects(0);
skipped = {};

if nargin < 2 || isempty(keys)
    if isfield(S.h, 'lst_figs') && ishandle(S.h.lst_figs)
        all_keys = resultFigureKeys();
        sel = get(S.h.lst_figs, 'Value');
        keys = all_keys(sel);
    else
        keys = resultFigureKeys();
    end
end
want = @(k) any(strcmp(keys, k));

haveR = ~isempty(S.dose.rashi_Gy);
haveL = ~isempty(S.dose.local_Gy);
haveA = ~isempty(S.dose.after_Gy);
pair  = haveR && haveL && sameGeom(S.dose.PusedRashi, S.dose.PusedLocal);
caseName = sprintf('A-%dmm-B-%dmm-FWHM%gmm-replicated-pins', ...
                   round(P.heightA_mm), round(P.heightB_mm), P.fwhm0_mm);

setStatus(fig, 'Building the result figures ...'); drawnow;
[ddd, rng] = loadTables(P);

% --- parameter-only figures: no dose needed
if want('fig1_geometry'),  H(end+1) = figGeometry(P, vis);          end
if want('fig6_scatter_sigma'), H(end+1) = figSigma(P, ddd, rng, vis); end
if want('nl_fig1_mechanism'),  H(end+1) = figMechanism(vis); end
if want('nl_fig2_delta_phi'),  H(end+1) = figDeltaPhi(vis);  end
if want('fig8_geometry_3d'),   H(end+1) = figGeometry3D(P, vis);     end

% --- needs F_R / F_M (computed on demand): fig2_level_spectrum
if want('fig2_level_spectrum')
    [ok2, F_R, F_M, grid2] = computeFluencePair(P, ddd, rng);
    if ok2
        H(end+1) = figLevelSpectrum(P, grid2, F_R, F_M, vis);
    else
        skipped{end+1} = 'Level spectrum: could not build the pin geometry';
    end
end

% --- need both doses
pairWanted = want('fig3_dose_maps_yz') || want('fig4_depth_dose') || ...
             want('fig5_lateral_profiles') || want('fig7_dD_xy');
if pairWanted
    if pair
        if want('fig3_dose_maps_yz'),     H(end+1) = figDoseMapsYZ(S, P, caseName, vis);       end
        if want('fig4_depth_dose'),       H(end+1) = figDepthDose(S, P, caseName, vis);        end
        if want('fig5_lateral_profiles'), H(end+1) = figLateralProfiles(S, P, ddd, rng, caseName, vis); end
        if want('fig7_dD_xy'),            H(end+1) = figDDxy(S, P, ddd, rng, caseName, vis);   end
    else
        r = 'press Calculate (RaShi) and Calculate (2DRM) first';
        if haveR && haveL
            r = 'the two doses use different parameters - recalculate both';
        end
        if want('fig3_dose_maps_yz'),     skipped{end+1} = sprintf('Dose maps y-z: %s', r); end
        if want('fig4_depth_dose'),       skipped{end+1} = sprintf('Depth-dose curves: %s', r); end
        if want('fig5_lateral_profiles'), skipped{end+1} = sprintf('Lateral dose profiles: %s', r); end
        if want('fig7_dD_xy'),            skipped{end+1} = sprintf('Dose difference in the x-y plane: %s', r); end
    end
end

% --- needs Apply as well
if want('nl_fig3_maps')
    if pair && haveA
        H(end+1) = figMapsYZ(S, P, ddd, rng, caseName, vis);
    else
        skipped{end+1} = 'Dose difference maps y-z (non-locality): press Apply non-locality model first';
    end
end

if isempty(skipped)
    setStatus(fig, 'Result: %d figure(s) generated.', numel(H));
else
    setStatus(fig, 'Result: %d figure(s) generated. Skipped - %s', ...
              numel(H), strjoin(skipped, ' | '));
end
end


function [ok, F_R, F_M, grid] = computeFluencePair(P, ddd, rng)
%COMPUTEFLUENCEPAIR  F_R and F_M on demand, for figLevelSpectrum.
ok = false;  F_R = [];  F_M = [];  grid = [];
C = derivedCounts(P);
if C.K <= 0, return; end
spots        = makeSpots(P);
N            = rashiWeights(P, spots);
[pins, info] = buildPins(P, spots);
halfX = max(abs(info.pinned_x_mm)) + P.lateral_margin_mm;
halfY = max(abs(info.pinned_y_mm)) + P.lateral_margin_mm;
grid  = makeGrid(halfX, halfY, P.lateral_pixel_mm);
sig0  = P.fwhm0_mm * FWHM2SIG();
F_R   = fluenceRashi(grid, spots, N, sig0);
W     = sum(N, 2);
F_M   = fluence2drm(grid, spots, W, sig0, pins, P.spacing_mm, C.K);
ok = true;
end


function f = newResultFig(name, vis, w, h, pngPath, dpi)
%NEWRESULTFIG  A plain pop-up figure, inheriting the GUI's visibility.
%   w, h are in PIXELS and are chosen, at every call site, to be exactly the
%   Python reference figsize (inches) x 100 -- e.g. figsize (13, 5.2) becomes
%   w=1300, h=520.  That convention is what lets btn_savefigs (onSaveFigs,
%   PLAN3.md P5) reproduce the exact reference pixel dimensions later just by
%   reinterpreting this same Position in inches (Position/100 = figsize),
%   with no separate figsize bookkeeping.
%   pngPath/dpi (optional): the Python-reference filename (relative to the
%   output dir, nonlocality/ figures included) and export resolution, stashed
%   in UserData so onSaveFigs can export each open figure without
%   re-deriving its name -- PLAN3.md section 6.4's prerequisite for P5.
f = figure('Name', name, 'NumberTitle', 'off', 'Visible', vis, ...
           'Color', 'w', 'Position', [80 80 w h], 'Tag', 'drm2d_result');
if nargin >= 6 && ~isempty(pngPath)
    set(f, 'UserData', struct('png', pngPath, 'dpi', dpi));
end
end


function onSaveFigs(fig, outDir)
%ONSAVEFIGS  btn_savefigs / 'savefigs' command (PLAN3.md section 2.2, P5).
%   Exports every currently open Result figure (Tag 'drm2d_result') to PNG,
%   using the filename and dpi stashed in its UserData by newResultFig, and
%   the Python reference figsize (PLAN3.md section 2.2's table) by setting
%   Position explicitly in inches from the SAME w/h/100 convention newResultFig
%   used (NOT a bare Units-to-inches switch, which would depend on the screen
%   DPI MATLAB assumes rather than on that convention).  Costs nothing when
%   no Result figures are open, and never recomputes anything -- it only
%   reads what is already on screen.
if nargin < 2 || isempty(outDir)
    if strcmpi(get(fig, 'Visible'), 'off')
        error('drm2d:needOutDir', ...
              'savefigs requires an explicit outDir when the tool is headless (-batch).');
    end
    outDir = uigetdir(pwd, 'Choose a folder for the PNG export');
    if isequal(outDir, 0)
        setStatus(fig, 'Save figures: cancelled.');
        return;
    end
end

figs = findobj('Type', 'figure', 'Tag', 'drm2d_result');
if isempty(figs)
    setStatus(fig, 'Save figures: no Result figures are open - press Result first.');
    return;
end

n = 0;
for i = 1:numel(figs)
    h  = figs(i);
    ud = get(h, 'UserData');
    if ~isstruct(ud) || ~isfield(ud, 'png'), continue; end
    outPath = fullfile(outDir, ud.png);
    outSub  = fileparts(outPath);
    if ~isempty(outSub) && exist(outSub, 'dir') ~= 7, mkdir(outSub); end

    u0 = get(h, 'Units');  p0 = get(h, 'Position');  r0 = get(h, 'Renderer');
    set(h, 'Units', 'inches');
    pIn = get(h, 'Position');
    set(h, 'Position', [pIn(1), pIn(2), p0(3)/100, p0(4)/100]);   % exact figsize
    % 'painters' matters, not cosmetic: with the default OpenGL renderer, an
    % invisible figure wider than the (possibly virtual/headless) screen is
    % silently clamped to the screen's pixel width before export, so a wide
    % figure like fig7 (17.6 in) comes out ~35% narrow on a 1366-px display.
    % Measured and confirmed on this machine; painters has no such limit.
    set(h, 'Renderer', 'painters');
    exportgraphics(h, outPath, 'Resolution', ud.dpi);
    set(h, 'Units', u0, 'Position', p0, 'Renderer', r0);          % restore on-screen state
    n = n + 1;
end
setStatus(fig, 'Save figures: wrote %d PNG(s) to %s.', n, outDir);
end


function [xv, yv] = stepMid(x, y)
%STEPMID  Vertices matching matplotlib's step(..., where='mid') exactly
%   (PLAN3.md section 7.1).  NOT an extended half-step: the OUTER edges are
%   clamped to x(1)/x(end), so the first and last blocks are half-width.
x = x(:).';  y = y(:).';
e = [x(1), 0.5*(x(1:end-1) + x(2:end)), x(end)];      % N+1 edges
xv = reshape([e(1:end-1); e(2:end)], 1, []);          % 2N
yv = reshape([y; y], 1, []);                          % 2N
end


function fillStepMid(ax, x, y, mask, color, alpha)
%FILLSTEPMID  fill_between(x, 0, y, step='mid', where=mask) for ONE
%   contiguous run of mask (sufficient for the two-block a_k spectrum this is
%   used for).  Ports the matplotlib fill_between(step='mid') edge convention
%   via stepMid, then closes the polygon down to y = 0.
idx = find(mask(:));
if isempty(idx), return; end
[xv, yv] = stepMid(x, y);
i1 = idx(1);  i2 = idx(end);
sel = (2*i1-1) : (2*i2);
xs = [xv(sel(1)), xv(sel), xv(sel(end))];
ys = [0,          yv(sel), 0];
patch(ax, xs, ys, color, 'FaceAlpha', alpha, 'EdgeColor', 'none');
end


function f = figGeometry(P, vis)
%FIGGEOMETRY  Ports analysis.fig_geometry (1x2).  New figure (PLAN3.md P4).
%   DEVIATION (documented): Python hard-codes the planned-field box and the
%   profile panel's grey span at the literal +-15 mm of its one frozen
%   reference case.  This GUI must stay correct away from that case, so both
%   use P.widthA_mm/P.widthB_mm instead -- the two are numerically identical
%   at the reference/default geometry (widthA = widthB = 15).
f = newResultFig('2DRM geometry  [fig1_geometry]', vis, 1300, 520, 'fig1_geometry.png', 150);
C = derivedCounts(P);
if C.K <= 0
    annotation(f, 'textbox', [0.3 0.45 0.4 0.1], 'String', ...
               'no modulator (both heights 0)', 'EdgeColor', 'none');
    return;
end
spots = makeSpots(P);
[pins, info] = buildPins(P, spots);
lw = levelWeplNominal(P);
lo = info.pinned_y_mm(1);  hi = info.pinned_y_mm(2);
n  = round((hi - lo) / 0.05);
x  = lo + ((0:n-1) + 0.5) * 0.05;
T  = thicknessMap(pins, lw, x, x, P.spacing_mm) / P.height_scale;   % PMMA mm, (ix,iy)

ax = subplot('Position', [0.055 0.11 0.36 0.80], 'Parent', f);
imagesc(ax, x, x, T.');  set(ax, 'YDir', 'normal');  axis(ax, 'image');
colormap(ax, cmapTable('viridis'));
cb = colorbar(ax);
cb.Label.String = sprintf('PMMA thickness [mm]  (= WEPL / %.3f)', P.height_scale);
hold(ax, 'on');
plot(ax, spots.x_mm, spots.y_mm, 'w.', 'MarkerSize', 3);
plot(ax, [x(1) x(end)], [0 0], 'r-', 'LineWidth', 1);
plot(ax, [-P.widthA_mm P.widthB_mm P.widthB_mm -P.widthA_mm -P.widthA_mm], ...
         [-P.widthA_mm -P.widthA_mm P.widthB_mm P.widthB_mm -P.widthA_mm], ...
         'w--', 'LineWidth', 0.8);
hold(ax, 'off');
xlabel(ax, 'x [mm]');  ylabel(ax, 'y [mm]');
title(ax, '2DRM top view (dots: spots, red: y = 0)', 'FontSize', 10);

ax = subplot('Position', [0.50 0.11 0.47 0.80], 'Parent', f);
hold(ax, 'on');
cuts = {1.5, [0 0 0]; 13.5, [1 0.498 0.055]; 16.5, [0.580 0.404 0.741]};
for i = 1:size(cuts,1)
    xr = cuts{i,1};  col = cuts{i,2};
    [~, j] = min(abs(x - xr));
    [xv, yv] = stepMid(x, T(j,:));
    plot(ax, xv, yv, 'Color', col, 'LineWidth', 1, 'DisplayName', sprintf('x = %g mm', xr));
end
yl = ylim(ax);
plot(ax, [0 0], yl, 'r-', 'LineWidth', 0.8);
patch(ax, [-P.widthA_mm P.widthB_mm P.widthB_mm -P.widthA_mm], [yl(1) yl(1) yl(2) yl(2)], ...
      [0.92 0.92 0.92], 'EdgeColor', 'none');
uistack(findobj(ax, 'Type', 'patch'), 'bottom');
ylim(ax, yl);
hold(ax, 'off');
xlabel(ax, 'y [mm]');  ylabel(ax, 'PMMA thickness [mm]');
title(ax, 'Cuts through pin centres (grey: planned field)', 'FontSize', 10);
legend(ax, 'FontSize', 8);
end


function S = cellLevelSpectrum(F, grid, row_x0, row_x1, y_edges)
%CELLLEVELSPECTRUM  Ions per level summed over rectangles [row_x0,row_x1] x
%   [y_edges(i),y_edges(i+1)].  Ports analysis.cell_level_spectrum (PLAN3.md
%   section 3, P3).  STRICT > / < on both axes (PLAN3.md section 7.3) -- it
%   does not matter numerically (pixel centres never land exactly on a cell
%   edge) but is written strict so it stays correct if the pixel size changes.
%   Result is a SUM over the selected pixels, not a mean.  Returns (K+1,
%   nCells) to match Python's level-first F layout, even though MATLAB's F
%   itself is (nx,ny,K+1).
ix = (grid.xc_mm > row_x0) & (grid.xc_mm < row_x1);
K1 = size(F, 3);
nCell = numel(y_edges) - 1;
S = zeros(K1, nCell);
Fsub = F(ix, :, :);                      % (nxSel, ny, K+1)
for i = 1:nCell
    iy  = (grid.yc_mm > y_edges(i)) & (grid.yc_mm < y_edges(i+1));
    blk = Fsub(:, iy, :);                 % (nxSel, nySel, K+1)
    S(:, i) = squeeze(sum(sum(blk, 1), 2));
end
end


function f = figLevelSpectrum(P, grid, F_R, F_M, vis)
%FIGLEVELSPECTRUM  Ports analysis.fig_level_spectrum (1x3).  New figure
%   (PLAN3.md P4).  Needs cellLevelSpectrum (P3).
spots = makeSpots(P);
[~, info] = buildPins(P, spots);
D  = P.spacing_mm;
lo = info.pinned_y_mm(1);  hi = info.pinned_y_mm(2);
n  = round((hi - lo) / D);
ye = lo + (0:n)' * D;
yc = 0.5*(ye(1:end-1) + ye(2:end));
SR = cellLevelSpectrum(F_R, grid, 0.0, 3.0, ye);
SM = cellLevelSpectrum(F_M, grid, 0.0, 3.0, ye);
K  = size(SR, 1) - 1;
vmax = max(max(SR(:)), max(SM(:)));
d    = SM - SR;
lim  = max(abs(d(:)));
if lim <= 0, lim = 1; end

f = newResultFig('Level spectrum (ions per level per pin cell)  [fig2_level_spectrum]', ...
                 vis, 1500, 460, 'fig2_level_spectrum.png', 150);
panelsData = {SR, 'RaShi'; SM, '2DRM'};
for i = 1:2
    ax = subplot(1, 3, i, 'Parent', f);
    imagesc(ax, yc, 0:K, panelsData{i,1}, [0 vmax]);
    set(ax, 'YDir', 'normal');
    colormap(ax, cmapTable('magma'));
    hold(ax, 'on');  plot(ax, [0 0], [-0.5 K+0.5], 'c-', 'LineWidth', 0.8);  hold(ax, 'off');
    title(ax, sprintf('%s: ions per level per pin cell (x in [0,3] mm)', panelsData{i,2}), 'FontSize', 9);
    xlabel(ax, 'y [mm] (pin-cell columns)');
    if i == 1, ylabel(ax, 'level k  (WEPL = k mm; 0 = no material)'); end
    if i == 2, cb = colorbar(ax);  ylabel(cb, 'ions'); end
end
ax = subplot(1, 3, 3, 'Parent', f);
imagesc(ax, yc, 0:K, d, [-lim lim]);
set(ax, 'YDir', 'normal');
colormap(ax, cmapTable('RdBu_r'));
hold(ax, 'on');  plot(ax, [0 0], [-0.5 K+0.5], 'k-', 'LineWidth', 0.8);  hold(ax, 'off');
cb = colorbar(ax);  ylabel(cb, '2DRM - RaShi [ions]');
title(ax, 'Difference (before scattering, device exit)', 'FontSize', 9);
xlabel(ax, 'y [mm] (pin-cell columns)');
end


function f = figDoseMapsYZ(S, P, caseName, vis)
%FIGDOSEMAPSYZ  Ports analysis.fig_dose_maps (1x3).  New figure (PLAN3.md P4).
[M, src] = pyRefDose(S);
f = newResultFig(sprintf('Dose maps y-z (RaShi / 2DRM / difference)  [fig3_dose_maps_yz]  (2DRM: %s)  %s', ...
                         src, caseName), vis, 1500, 480, 'fig3_dose_maps_yz.png', 150);
xe = S.dose.xEdges_mm;  ye = S.dose.yEdges_mm;  ze = S.dose.zEdges_mm;
xc = 0.5*(xe(1:end-1) + xe(2:end));
yc = 0.5*(ye(1:end-1) + ye(2:end));
zc = 0.5*(ze(1:end-1) + ze(2:end));
[~, ix] = min(abs(xc - 0.5));
R    = squeeze(S.dose.rashi_Gy(:, ix, :));
Mx   = squeeze(M(:, ix, :));
Rmax = max(S.dose.rashi_Gy(:));

ax = subplot(1, 3, 1, 'Parent', f);
imagesc(ax, yc, zc, R, [0 Rmax]);  set(ax, 'YDir', 'reverse');
colormap(ax, cmapTable('jet'));
hold(ax, 'on');  plot(ax, [0 0], [zc(1) zc(end)], 'w-', 'LineWidth', 0.6);  hold(ax, 'off');
xlim(ax, [-30 30]);  xlabel(ax, 'y [mm]');  ylabel(ax, 'depth z in water [mm]');
title(ax, sprintf('RaShi dose, x = %.1f mm', xc(ix)), 'FontSize', 9);

ax = subplot(1, 3, 2, 'Parent', f);
imagesc(ax, yc, zc, Mx, [0 Rmax]);  set(ax, 'YDir', 'reverse');
colormap(ax, cmapTable('jet'));
hold(ax, 'on');  plot(ax, [0 0], [zc(1) zc(end)], 'w-', 'LineWidth', 0.6);  hold(ax, 'off');
xlim(ax, [-30 30]);  xlabel(ax, 'y [mm]');
title(ax, sprintf('2DRM dose, x = %.1f mm', xc(ix)), 'FontSize', 9);
cb = colorbar(ax);  ylabel(cb, 'dose [Gy]');

d   = (Mx - R) / Rmax * 100;
lim = max(max(abs(d(:))), 0.5);
ax  = subplot(1, 3, 3, 'Parent', f);
imagesc(ax, yc, zc, d, [-lim lim]);  set(ax, 'YDir', 'reverse');
colormap(ax, cmapTable('RdBu_r'));
hold(ax, 'on');
contour(ax, yc, zc, R/Rmax, [0.5 0.5], 'k', 'LineWidth', 0.7);
hold(ax, 'off');
xlim(ax, [-30 30]);  xlabel(ax, 'y [mm]');
title(ax, 'Dose difference (black: 50 % RaShi isodose)', 'FontSize', 9);
cb = colorbar(ax);  ylabel(cb, '(2DRM - RaShi) / max(RaShi) [%]');
end


function f = figSigma(P, ddd, rng, vis)
%FIGSIGMA  Ports analysis.fig_sigma.  New figure (PLAN3.md P4, cheapest).
%   NOTE the hard-coded 2.3548 in Python's axhline(fwhm0_mm/2.3548) is NOT
%   1/FWHM2SIG() (2.354820045...) -- reproduced here deliberately, per
%   PLAN3.md section 6.1 ("note the hard-coded 2.3548 ... reproduce the
%   discrepancy").
C_R = [0.1216 0.3725 0.6588];  C_M = [0.8196 0.2863 0.3569];
f = newResultFig('Device-only lateral sigma vs WEPL  [fig6_scatter_sigma]', ...
                 vis, 600, 400, 'fig6_scatter_sigma.png', 150);
lp_R = levelProps(P, 'rashi', rng);
lp_M = levelProps(P, '2drm',  rng);
K  = numel(lp_R.wepl_mm) - 1;
ks = (1:K)';
ax = axes('Parent', f);
hold(ax, 'on');
plans = {lp_R, C_R, 'RaShi (water)'; lp_M, C_M, '2DRM (PMMA)'};
for i = 1:2
    lp  = plans{i,1};  col = plans{i,2};  lab = plans{i,3};
    sig = lp.thetaDev_rad(ks+1) .* sqrt(slabLever2(lp.tGeom_mm(ks+1), lp.dExit0_mm(ks+1)));
    plot(ax, lp.wepl_mm(ks+1), sig, 'Color', col, 'LineWidth', 1.3, 'DisplayName', lab);
end
xl = xlim(ax);
plot(ax, xl, [1 1] * P.fwhm0_mm / 2.3548, 'Color', [0.5 0.5 0.5], 'LineStyle', ':', ...
     'DisplayName', 'initial sigma0');
hold(ax, 'off');
xlabel(ax, 'device WEPL [mm]');
ylabel(ax, 'sigma from device scattering at phantom entrance [mm]');
title(ax, sprintf('Highland MCS + %.0f mm drift', P.gap_mm), 'FontSize', 10);
legend(ax, 'Location', 'best');
end


function [gx, gy, T] = height3D(pins, lw, P, x0, x1, y0, y1, h)
%HEIGHT3D  PMMA height [mm] on a regular grid of pitch h, plus the grid
%   centres.  Ports make_geometry_3d.height_map.
n1 = round((x1 - x0) / h);  n2 = round((y1 - y0) / h);
gx = x0 + ((0:n1-1) + 0.5) * h;
gy = y0 + ((0:n2-1) + 0.5) * h;
T  = thicknessMap(pins, lw, gx, gy, P.spacing_mm) / P.height_scale;
end


function draw3D(ax, gx, gy, T, vmax, elev, azim, zbox, ttl)
%DRAW3D  One viridis surf panel.  Ports make_geometry_3d.draw.
surf(ax, gx, gy, T.', 'EdgeColor', 'none');
view(ax, azim, elev);
pbaspect(ax, [1 1 zbox]);
xlabel(ax, 'x [mm]', 'FontSize', 8);
ylabel(ax, 'y [mm]', 'FontSize', 8);
zlabel(ax, 'PMMA height [mm]', 'FontSize', 8);
set(ax, 'FontSize', 7);
zlim(ax, [0, max(vmax * 1.02, 1e-9)]);
caxis(ax, [0 vmax]);
title(ax, ttl, 'FontSize', 9);
end


function f = figGeometry3D(P, vis)
%FIGGEOMETRY3D  Ports make_geometry_3d.py (1x3 surf panels).  New figure,
%   LOWEST PRIORITY (PLAN3.md P6) -- purely illustrative, contains no dose.
%   matplotlib's set_box_aspect + subplots_adjust(top=1.04,bottom=-0.02) have
%   no exact MATLAB equivalent, so the margins are approximate only; the
%   surfaces and view angles reproduce.
f = newResultFig('3D pin geometry  [fig8_geometry_3d]', vis, 1600, 520, 'fig8_geometry_3d.png', 130);
C = derivedCounts(P);
if C.K <= 0
    annotation(f, 'textbox', [0.3 0.45 0.4 0.1], 'String', ...
               'no modulator (both heights 0)', 'EdgeColor', 'none');
    return;
end
spots = makeSpots(P);
[pins, info] = buildPins(P, spots);
lw = levelWeplNominal(P);
lo = info.pinned_y_mm(1);  hi = info.pinned_y_mm(2);
vmax = max(lw) / P.height_scale;
z = 6.0;  fieldHalf = max(P.widthA_mm, P.widthB_mm);

ax = subplot(1, 3, 1, 'Parent', f);
[gx, gy, T] = height3D(pins, lw, P, lo, hi, lo, hi, 0.2);
draw3D(ax, gx, gy, T, vmax, 34, -62, 0.45, ...
       sprintf('whole 2DRM, %g to %g mm\nzone A (y<0) %g mm WEPL   |   zone B (y>0) %g mm WEPL', ...
               lo, hi, P.heightA_mm, P.heightB_mm));

ax = subplot(1, 3, 2, 'Parent', f);
[gx, gy, T] = height3D(pins, lw, P, -z, z, -z, z, 0.04);
draw3D(ax, gx, gy, T, vmax, 24, -72, 0.6, 'zoom: A/B zone boundary at y = 0 (4 x 4 in-field pins)');

ax = subplot(1, 3, 3, 'Parent', f);
[gx, gy, T] = height3D(pins, lw, P, -z, z, fieldHalf - z, fieldHalf + z, 0.04);
draw3D(ax, gx, gy, T, vmax, 24, -72, 0.6, ...
       sprintf('zoom: zone B field edge at y = +%g mm (in-field -> outside-field pins)', fieldHalf));

if P.gauss_expand, modeStr = P.expand_mode; else, modeStr = 'no expansion'; end
sgtitle(f, sprintf(['expand_mode = ''%s''   |   %d pins (%d in-field, %d expansion rings)   |   ' ...
                    'height scale 1/%g'], modeStr, info.n_pins, info.n_original, info.n_expand, ...
                   P.height_scale), 'FontSize', 11);
colormap(f, cmapTable('viridis'));
cb = colorbar(ax);  cb.Label.String = 'PMMA height [mm]';
end


function f = figMechanism(vis)
%FIGMECHANISM  Ports figs_nonlocality.fig_mechanism (1x3) EXACTLY as Python
%   does: hard-coded K_A=60/K_B=40 (panel a) and FWHM in {6,10} (panels b,c),
%   ignoring whatever is on screen (PLAN3.md section 11 decision 1).  This
%   figure is therefore PARAMETER-INDEPENDENT -- it never changes when the
%   GUI parameters change -- hence the note in its Name.
C_NL  = [0.8196 0.2863 0.3569];   % #d1495b
C_MAT = [0.1216 0.3725 0.6588];   % #1f5fa8
f = newResultFig(['Non-locality mechanism  [nl_fig1_mechanism]  ' ...
                  '(EXACT Python reproduction -- PARAMETER-INDEPENDENT: K_A=60, K_B=40, FWHM 6+10)'], ...
                 vis, 1550, 440, 'nonlocality/fig1_mechanism.png', 150);

Pa = defaultParams();  Pa.heightB_mm = 40;  Pa.fwhm0_mm = 6;
[ddd, rng] = loadTables(Pa);
[KA, KB, K] = zoneLevels(Pa);
a = spectralWeight(Pa);
[~, exc, dfc] = depthWindows(Pa, ddd, rng);
k = (1:K)';

ax = subplot(1, 3, 1, 'Parent', f);
[xv, yv] = stepMid(k, a);
plot(ax, xv, yv, 'Color', C_NL, 'LineWidth', 1.6);
hold(ax, 'on');
fillStepMid(ax, k, a, k <= KB, C_NL,  0.25);
fillStepMid(ax, k, a, k >  KB, C_MAT, 0.25);
plot(ax, [xv(1) xv(end)], [0 0], 'Color', [0.5 0.5 0.5], 'LineWidth', 0.8);
ylim(ax, [-KB*1.6, (KA-KB)*2.6]);
yl = ylim(ax);
text(ax, KB*0.45, (KA-KB) + 0.10*diff(yl), ...
     sprintf('+dK = +%d\nzone B''s own SOBP\nz = %.0f-%.0f mm', KA-KB, exc(1), exc(2)), ...
     'HorizontalAlignment', 'center', 'FontSize', 8, 'Color', C_NL);
text(ax, (KB+KA)/2, -KB - 0.10*diff(yl), ...
     sprintf('-K_B = -%d\n''A-only'' window\nz = %.0f-%.0f mm', KB, dfc(1), dfc(2)), ...
     'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', 'FontSize', 8, 'Color', C_MAT);
hold(ax, 'off');
xlabel(ax, 'level k   (WEPL = k mm; Bragg peak at z = R0 - k)');
ylabel(ax, 'spectral weight a_k');
title(ax, 'spectrum: two blocks, sum_k a_k = 0 -- the non-locality only RE-LABELS depth', 'FontSize', 9);
xlim(ax, [k(1) k(end)]);  grid(ax, 'on');

ax2 = subplot(1, 3, 2, 'Parent', f);  hold(ax2, 'on');
ax3 = subplot(1, 3, 3, 'Parent', f);  hold(ax3, 'on');
fwhms  = [6 10];
styles = {'-', '--'};
for m = 1:2
    q = defaultParams();  q.heightB_mm = 40;  q.fwhm0_mm = fwhms(m);
    [yc, fA] = fZoneA(q);
    [~, ~, ~, ~, v] = spatialProfile(q);
    vn = v / (max(abs(v(~isnan(v)))) + eps);
    [xv2, yv2] = stepMid(yc, vn);
    plot(ax2, xv2, yv2, 'LineStyle', styles{m}, 'Color', C_NL, 'LineWidth', 1.3, ...
         'DisplayName', sprintf('u(y) normalised, FWHM %d', fwhms(m)));
    [xv3, yv3] = stepMid(yc, fA);
    plot(ax3, xv3, yv3, 'LineStyle', styles{m}, 'Color', C_MAT, 'LineWidth', 1.3, ...
         'DisplayName', sprintf('f_A(y), FWHM %d', fwhms(m)));
end
for axn = [ax2, ax3]
    yl2 = ylim(axn);
    plot(axn, [0 0], yl2, 'r-', 'LineWidth', 0.8);
    patch(axn, [-15 15 15 -15], [yl2(1) yl2(1) yl2(2) yl2(2)], [0.92 0.92 0.92], 'EdgeColor', 'none');
    uistack(findobj(axn, 'Type', 'patch'), 'bottom');
    ylim(axn, yl2);
    xlabel(axn, 'y [mm]');  xlim(axn, [-24 24]);
    legend(axn, 'FontSize', 8);
end
plot(ax2, xlim(ax2), [0 0], 'Color', [0.5 0.5 0.5], 'LineWidth', 0.8);
hold(ax2, 'off');  hold(ax3, 'off');
ylabel(ax2, 'spatial profile u(y) [normalised]');
title(ax2, ['profile: zone-A ions on zone-B pins (+) and ' ...
            'zone-B ions on zone-A pins (-)'], 'FontSize', 9);
ylabel(ax3, 'f_A = fraction of fluence from zone A spots');
title(ax3, 'the only place the beam FWHM enters', 'FontSize', 9);
end


function f = figDeltaPhi(vis)
%FIGDELTAPHI  Ports figs_nonlocality.fig_dphi_map (1x3) EXACTLY as Python
%   does: hard-coded K_B in {50,40,20} at FWHM 6, replicate (PLAN3.md section
%   11 decision 1) -- PARAMETER-INDEPENDENT, like figMechanism.
f = newResultFig(['Level-resolved fluence difference dPhi_k  [nl_fig2_delta_phi]  ' ...
                  '(EXACT Python reproduction -- PARAMETER-INDEPENDENT: K_B=50/40/20, FWHM 6)'], ...
                 vis, 1500, 420, 'nonlocality/fig2_delta_phi.png', 150);
KBs = [50 40 20];
for i = 1:3
    Pi = defaultParams();  Pi.heightB_mm = KBs(i);  Pi.fwhm0_mm = 6;
    [dPhi, xe, ye] = deltaPhiLevels(Pi);
    xc = 0.5*(xe(1:end-1) + xe(2:end));
    yc = 0.5*(ye(1:end-1) + ye(2:end));
    [~, ix] = min(abs(xc - 1.5));
    Z = squeeze(dPhi(ix, :, :)).';          % (K, ny)
    lim = max(abs(Z(:)));
    if lim <= 0, lim = 1; end
    ax = subplot(1, 3, i, 'Parent', f);
    imagesc(ax, yc, 1:size(Z,1), Z, [-lim lim]);
    set(ax, 'YDir', 'normal');
    colormap(ax, cmapTable('RdBu_r'));
    hold(ax, 'on');
    plot(ax, [0 0], [0.5 size(Z,1)+0.5], 'k-', 'LineWidth', 1);
    plot(ax, [yc(1) yc(end)], [KBs(i)+0.5 KBs(i)+0.5], 'k--', 'LineWidth', 0.8);
    hold(ax, 'off');
    xlim(ax, [-24 24]);
    xlabel(ax, 'y [mm]');
    if i == 1, ylabel(ax, 'level k'); end
    title(ax, sprintf('dPhi_k, zone B = %d mm, FWHM 6 mm', KBs(i)), 'FontSize', 9);
    cb = colorbar(ax);  ylabel(cb, 'ions per pin cell');
end
sgtitle(f, ['Closed-form non-locality: one spatial dipole x a two-block spectrum ' ...
            '(dashed: k = K_B)'], 'FontSize', 10);
end


function f = figDepthDose(S, P, caseName, vis)
%FIGDEPTHDOSE  Ports analysis.fig_depth_dose (2 x 4).  PLAN3.md section 6.1:
%   M is now pyRefDose (was after_Gy with a local fallback to local_Gy);
%   recoloured to C_R/C_M/C_D (the bottom row was a non-Python green).  Uses
%   the SINGLE-x slice, as the Python original does.
C_R = [0.1216 0.3725 0.6588];  C_M = [0.8196 0.2863 0.3569];  C_D = [0.1647 0.1647 0.1647];
[M, src] = pyRefDose(S);
f = newResultFig(sprintf('Depth-dose curves  [fig4_depth_dose]  (2DRM: %s)  %s', src, caseName), ...
                 vis, 1600, 650, 'fig4_depth_dose.png', 150);
xe = S.dose.xEdges_mm;  ye = S.dose.yEdges_mm;  ze = S.dose.zEdges_mm;
yc = 0.5*(ye(1:end-1) + ye(2:end));
zc = 0.5*(ze(1:end-1) + ze(2:end));
R  = sliceSingleX(S.dose.rashi_Gy, xe);
M  = sliceSingleX(M, xe);
Rmax = max(S.dose.rashi_Gy(:));
ys   = [-7.5 -1.5 1.5 7.5];
for n = 1:4
    [~, j] = min(abs(yc - ys(n)));
    ax = subplot(2, 4, n, 'Parent', f);
    plot(ax, zc, R(:,j), '-',  'Color', C_R, 'LineWidth', 1.2); hold(ax,'on');
    plot(ax, zc, M(:,j), '--', 'Color', C_M, 'LineWidth', 1.2); hold(ax,'off');
    if yc(j) < 0, zn = 'A'; else, zn = 'B'; end
    title(ax, sprintf('y = %+.1f mm  (Region %s)', yc(j), zn), 'FontSize', 9);
    grid(ax, 'on');
    if n == 1
        ylabel(ax, 'dose [Gy]');
        legend(ax, {'RaShi', '2DRM'}, 'Location', 'northwest', 'FontSize', 7);
    end
    ax = subplot(2, 4, 4+n, 'Parent', f);
    plot(ax, zc, (M(:,j) - R(:,j)) / Rmax * 100, 'Color', C_D, 'LineWidth', 1.1);
    hold(ax, 'on');  plot(ax, [zc(1) zc(end)], [0 0], 'Color', [0.6 0.6 0.6]);  hold(ax, 'off');
    xlabel(ax, 'depth z [mm]');  grid(ax, 'on');
    if n == 1, ylabel(ax, 'dD / max(RaShi) [%]'); end
end
end


function d = profileDepths(P, ddd, rng)
%PROFILEDEPTHS  The three depths analysis.py profiles at, generalised.
%   Python hardcodes R0-50, R0-30, R0-10 for its K_A = 60 case; the same
%   fractions of K_A are used here so any geometry gives sensible depths.
[R0, ~, ~] = depthWindows(P, ddd, rng);
[KA, KB]   = zoneLevels(P);
K = max([KA, KB, 1]);
d = R0 - [5/6, 1/2, 1/6] * K;
end


function f = figLateralProfiles(S, P, ddd, rng, caseName, vis)
%FIGLATERALPROFILES  Ports analysis.fig_lateral (2 x 3).  PLAN3.md section
%   6.1: M -> pyRefDose; recoloured; xlim(-30,30) fixed (was +-(width+9)).
C_R = [0.1216 0.3725 0.6588];  C_M = [0.8196 0.2863 0.3569];  C_D = [0.1647 0.1647 0.1647];
[M, src] = pyRefDose(S);
f = newResultFig(sprintf('Lateral dose profiles  [fig5_lateral_profiles]  (2DRM: %s)  %s', src, caseName), ...
                 vis, 1380, 650, 'fig5_lateral_profiles.png', 150);
xe = S.dose.xEdges_mm;  ye = S.dose.yEdges_mm;  ze = S.dose.zEdges_mm;
yc = 0.5*(ye(1:end-1) + ye(2:end));
zc = 0.5*(ze(1:end-1) + ze(2:end));
R  = sliceSingleX(S.dose.rashi_Gy, xe);
M  = sliceSingleX(M, xe);
Rmax   = max(S.dose.rashi_Gy(:));
depths = profileDepths(P, ddd, rng);
yl     = [-30 30];
for n = 1:3
    [~, k] = min(abs(zc - depths(n)));
    ax = subplot(2, 3, n, 'Parent', f);
    plot(ax, yc, R(k,:), '-',  'Color', C_R, 'LineWidth', 1.2); hold(ax,'on');
    plot(ax, yc, M(k,:), '--', 'Color', C_M, 'LineWidth', 1.2);
    plot(ax, [0 0], ylim(ax), 'r-', 'LineWidth', 0.6);  hold(ax, 'off');
    title(ax, sprintf('lateral profile, z = %.1f mm', zc(k)), 'FontSize', 9);
    xlim(ax, yl);  grid(ax, 'on');
    if n == 1
        ylabel(ax, 'dose [Gy]');
        legend(ax, {'RaShi', '2DRM'}, 'Location', 'southwest', 'FontSize', 7);
    end
    ax = subplot(2, 3, 3+n, 'Parent', f);
    plot(ax, yc, (M(k,:) - R(k,:)) / Rmax * 100, 'Color', C_D, 'LineWidth', 1.1);
    hold(ax, 'on');
    plot(ax, yl, [0 0], 'Color', [0.6 0.6 0.6]);
    plot(ax, [0 0], ylim(ax), 'r-', 'LineWidth', 0.6);  hold(ax, 'off');
    xlabel(ax, 'y [mm]');  xlim(ax, yl);  grid(ax, 'on');
    if n == 1, ylabel(ax, 'dD / max(RaShi) [%]'); end
end
end


function f = figDDxy(S, P, ddd, rng, caseName, vis)
%FIGDDXY  Ports analysis.fig_xy (1 x 4): the difference in the x-y plane.
%   PLAN3.md section 6.1: M -> pyRefDose; xlim/ylim FIXED at (-24,24) (Python
%   hard-codes this -- it is not a function of the field widths).
[M, src] = pyRefDose(S);
f = newResultFig(sprintf('Dose difference in the x-y plane  [fig7_dD_xy]  (2DRM: %s)  %s', src, caseName), ...
                 vis, 1760, 420, 'fig7_dD_xy.png', 150);
xe = S.dose.xEdges_mm;  ye = S.dose.yEdges_mm;  ze = S.dose.zEdges_mm;
xc = 0.5*(xe(1:end-1) + xe(2:end));
yc = 0.5*(ye(1:end-1) + ye(2:end));
zc = 0.5*(ze(1:end-1) + ze(2:end));
R  = S.dose.rashi_Gy;
Rmax   = max(R(:));
depths = [20.0, profileDepths(P, ddd, rng)];
hw     = 24;
for n = 1:4
    [~, k] = min(abs(zc - depths(n)));
    d   = squeeze(M(k,:,:) - R(k,:,:)) / Rmax * 100;      % (nx, ny)
    lim = max(max(abs(d(:))), 0.5);
    ax  = subplot(1, 4, n, 'Parent', f);
    imagesc(ax, xc, yc, d.', [-lim lim]);
    set(ax, 'YDir', 'normal');  colormap(ax, cmapTable('RdBu_r'));
    hold(ax, 'on');
    wx = P.fieldX_mm/2;
    plot(ax, [-wx wx wx -wx -wx], ...
             [-P.widthA_mm -P.widthA_mm P.widthB_mm P.widthB_mm -P.widthA_mm], ...
             'k--', 'LineWidth', 0.6);
    plot(ax, [-hw hw], [0 0], 'k-', 'LineWidth', 0.6);
    hold(ax, 'off');
    xlim(ax, [-hw hw]);  ylim(ax, [-hw hw]);
    title(ax, sprintf('dD [%% max RaShi], z = %.1f mm', zc(k)), 'FontSize', 9);
    xlabel(ax, 'x [mm]');
    if n == 1, ylabel(ax, 'y [mm]'); end
    colorbar(ax);
end
end


function f = figMapsYZ(S, P, ddd, rng, caseName, vis)
%FIGMAPSYZ  Ports figs_nonlocality.fig_case_maps (1 x 4), y-z maps.
%   PLAN3.md section 6.2 (hardest port): cellAverage (NOT voxel x-averaging),
%   zoneReference (median, NOT perZoneRef's zone max) for the normalisation,
%   predictMaterialTerm (closed form, NOT after_Gy - rashi_Gy) for the
%   NL+MAT panel, and the lim formula below (from the UN-averaged actual
%   sub-block, not the max over all four panels).
%
%   The four panels decompose the difference exactly as the model does:
%       actual   = exact  - rashi      (needs "Compare exact 2DRM")
%       NL       = nl                  (the non-locality term alone)
%       NL + MAT = NL + predictMaterialTerm
%       residual = actual - NL - MAT
f = newResultFig(sprintf('Dose difference maps y-z (actual / model / residual)  [nl_fig3_maps]  %s', ...
                         caseName), vis, 1800, 430, sprintf('nonlocality/fig3_maps_%s.png', caseName), 140);
xe = S.dose.xEdges_mm;  ye = S.dose.yEdges_mm;  ze = S.dose.zEdges_mm;
zc = 0.5*(ze(1:end-1) + ze(2:end));
D  = P.spacing_mm;
R  = S.dose.rashi_Gy;  NL = S.dose.nl_Gy;

half_mm = ceil(max(abs([xe(1), xe(end), ye(1), ye(end)])));
MAT = predictMaterialTerm(P, ddd, rng, P.voxel_mm, half_mm);
MAT = matchGrid(MAT, size(R));

[Rc, xec, yec] = cellAverage(R,   xe, ye, D);
[Nc, ~,   ~  ] = cellAverage(NL,  xe, ye, D);
[Mc, ~,   ~  ] = cellAverage(MAT, xe, ye, D);
xc = 0.5*(xec(1:end-1) + xec(2:end));
yc = 0.5*(yec(1:end-1) + yec(2:end));
mx = abs(xc) < 9;

[R0, exc, dfc]  = depthWindows(P, ddd, rng);
[DrefA, DrefB]  = zoneReference(Rc, xc, yc, zc, P, R0);
ref = DrefA * ones(size(yc));  ref(yc > 0) = DrefB;
refCol = reshape(ref, 1, []);
ref3   = reshape(ref, 1, 1, []);

havAct = exactIsCurrent(S);
if havAct
    Ac = cellAverage(S.dose.exact_Gy - R, xe, ye, D);
end

panels = {};
if havAct, panels{end+1} = {'actual  D_2DRM - D_RaShi', Ac};        end
panels{end+1}             = {'model: non-locality',            Nc};
panels{end+1}             = {'model: non-locality + material', Nc + Mc};
if havAct, panels{end+1} = {'residual (actual - model)', Ac - Nc - Mc}; end
npnl = numel(panels);

if havAct
    sub = Ac(:, mx, :) ./ ref3;
    lim = max(max(abs(sub(:))), 1e-9) * 100;
else
    lim = 0;
    for i = 1:npnl
        sub = panels{i}{2}(:, mx, :) ./ ref3;
        v = abs(sub(:));  v = v(isfinite(v));
        if ~isempty(v), lim = max(lim, max(v)); end
    end
    if ~isfinite(lim) || lim <= 0, lim = 1; end
end

Rz = squeeze(mean(Rc(:, mx, :), 2)) ./ refCol;
for i = 1:npnl
    V  = panels{i}{2};
    Z  = squeeze(mean(V(:, mx, :), 2)) ./ refCol * 100;
    ax = subplot(1, npnl, i, 'Parent', f);
    imagesc(ax, yc, zc, Z, [-lim lim]);
    set(ax, 'YDir', 'reverse');  colormap(ax, cmapTable('RdBu_r'));
    hold(ax, 'on');
    contour(ax, yc, zc, Rz, [0.5 0.5], 'k', 'LineWidth', 0.7);
    plot(ax, [0 0], [zc(1) zc(end)], 'k-', 'LineWidth', 0.8);
    if i <= min(3, npnl)
        plot(ax, [yc(1) yc(end)], [exc(1) exc(1)], 'g--', 'LineWidth', 0.8);
        plot(ax, [yc(1) yc(end)], [dfc(1) dfc(1)], 'g:',  'LineWidth', 0.8);
    end
    hold(ax, 'off');
    xlim(ax, [-16 16]);
    xlabel(ax, 'y [mm]');
    title(ax, panels{i}{1}, 'FontSize', 9);
    if i == 1, ylabel(ax, 'depth z [mm]'); end
    if i == npnl
        cb = colorbar(ax);  ylabel(cb, '% of the LOCAL zone plateau dose');
    end
end
if npnl < 4
    annotation(f, 'textbox', [0.01 0.94 0.98 0.05], 'String', ...
        ['Model panels only - tick "Compare exact 2DRM" and recalculate to add ' ...
         'the actual and residual panels.'], ...
        'EdgeColor', 'none', 'FontSize', 9, 'Color', [0.5 0.1 0.1]);
end
end


%% =============================================================== SELF TEST

function ok = selfTest(varargin)
%SELFTEST  Built-in checks.  Returns true if everything passed.
%   drm2d_nonlocality_tool('selftest')          -> fast checks only
%   drm2d_nonlocality_tool('selftest','full')   -> also compare against reference .mat
full = any(strcmpi(varargin, 'full'));
np = 0; nf = 0;

    function check(name, cond, detail)
        if nargin < 3, detail = ''; end
        if cond
            np = np + 1;  fprintf('  PASS  %s\n', name);
        else
            nf = nf + 1;  fprintf('  FAIL  %s   %s\n', name, detail);
        end
    end

fprintf('drm2d_nonlocality_tool self test\n--------------------------------\n');

% --- T15/T16: spectral weight conserves for every ordering
orders = [60 40; 40 40; 30 50; 60 1; 1 60; 10 10];
for i = 1:size(orders,1)
    P = defaultParams();
    P.heightA_mm = orders(i,1);  P.heightB_mm = orders(i,2);
    a = spectralWeight(P);
    check(sprintf('sum(a_k)=0 for K_A=%d K_B=%d', orders(i,1), orders(i,2)), ...
          abs(sum(a)) < 1e-9, sprintf('got %g', sum(a)));
end

% --- a_k matches the closed form in both orderings
P = defaultParams();  P.heightA_mm = 60;  P.heightB_mm = 40;
a = spectralWeight(P);
check('a_k shape K_A>K_B', all(a(1:40) == 20) && all(a(41:60) == -40));
P.heightA_mm = 30;  P.heightB_mm = 50;
a = spectralWeight(P);
check('a_k shape K_B>K_A', all(a(1:30) == -20) && all(a(31:50) == 30));

% --- T19: degenerate K_A == K_B gives identically zero dPhi
P = defaultParams();  P.heightA_mm = 40;  P.heightB_mm = 40;
dPhi = deltaPhiLevels(P);
check('K_A==K_B -> dPhi identically 0', max(abs(dPhi(:))) == 0);

% --- T17: sum_k dPhi_k = 0 in every cell
P = defaultParams();
dPhi = deltaPhiLevels(P);
s = sum(dPhi, 3);
check('sum_k dPhi_k = 0 per cell', max(abs(s(:))) < 1e-9 * max(abs(dPhi(:))), ...
      sprintf('max %g', max(abs(s(:)))));

% --- physics tables load and are monotonic
P = defaultParams();
[ddd, rng] = loadTables(P);
check('DDD loads', numel(ddd.z_mm) > 10 && all(diff(ddd.z_mm) > 0));
R0 = rangeFromEnergy(rng, 240);
check('range(240 MeV/u) in 110-130 mm', R0 > 110 && R0 < 130, sprintf('got %g', R0));
check('range/energy round trip', abs(energyFromRange(rng, R0) - 240) < 1e-6);

% --- ndtrStd
check('ndtrStd(0)=0.5', abs(ndtrStd(0) - 0.5) < 1e-15);
check('ndtrStd(inf)=1',  abs(ndtrStd(40) - 1.0) < 1e-15);

% --- GUI builds headless and every tagged control exists
f = apiNew('Visible', 'off');
S = guidata(f);
tags = {'pop_energy','edt_fwhm','edt_wA','edt_hA','edt_wB','edt_hB','edt_fx', ...
        'edt_D','pop_expand','chk_hifi','chk_exact','btn_calc','btn_apply', ...
        'btn_reset','txt_status','ax_geom','ax_prof','ax_before','ax_after', ...
        'ax_diff','ax_dd', ...
        'btn_rashi','btn_2drm','btn_diff','btn_result','txt_info'};   % PLAN2 T36
missing = tags(~cellfun(@(t) isfield(S.h, t) && ishandle(S.h.(t)), tags));
check('all GUI controls present', isempty(missing), strjoin(missing, ','));

% --- geometry plot is live
cd0 = get(findobj(S.h.ax_geom, 'Type', 'image'), 'CData');
drm2d_nonlocality_tool('set', f, 'heightB_mm', 20);
cd1 = get(findobj(guidata(f).h.ax_geom, 'Type', 'image'), 'CData');
check('geometry plot updates live', ~isequal(cd0, cd1));
drm2d_nonlocality_tool('set', f, 'heightB_mm', 40);

% --- invalid input handling
drm2d_nonlocality_tool('set', f, 'fwhm0_mm', 'abc');
check('non-numeric FWHM reverted', abs(guidata(f).P.fwhm0_mm - 6) < 1e-9);
drm2d_nonlocality_tool('set', f, 'fwhm0_mm', 3);
check('FWHM 3 clamped to 6', abs(guidata(f).P.fwhm0_mm - 6) < 1e-9);
drm2d_nonlocality_tool('set', f, 'fwhm0_mm', 12);
check('FWHM 12 clamped to 10', abs(guidata(f).P.fwhm0_mm - 10) < 1e-9);
drm2d_nonlocality_tool('set', f, 'fwhm0_mm', 6);
drm2d_nonlocality_tool('set', f, 'widthA_mm', 16);
check('width 16 snapped to 15', abs(guidata(f).P.widthA_mm - 15) < 1e-9);
drm2d_nonlocality_tool('set', f, 'widthA_mm', -5);
check('negative width rejected', guidata(f).P.widthA_mm > 0);
drm2d_nonlocality_tool('set', f, 'widthA_mm', 15);
drm2d_nonlocality_tool('set', f, 'energy_MeVu', 235);
check('energy 235 rejected', abs(guidata(f).P.energy_MeVu - 240) < 1e-9);

% --- coarse dose + immutability (T20-T23)
t0 = tic;
drm2d_nonlocality_tool('calculate', f);
tCalc = toc(t0);
S = guidata(f);
check('RaShi dose computed', ~isempty(S.dose.rashi_Gy) && max(S.dose.rashi_Gy(:)) > 0);
saved = S.dose.rashi_Gy;
afters = {};
for i = 1:5
    drm2d_nonlocality_tool('applynl', f);
    Si = guidata(f);
    afters{end+1} = Si.dose.after_Gy;   %#ok<AGROW>
end
S = guidata(f);
check('rashi_Gy bitwise unchanged after 5 applies', isequal(S.dose.rashi_Gy, saved));
same = true;
for i = 2:5, same = same && isequal(afters{i}, afters{1}); end
check('after_Gy identical across 5 applies (no accumulation)', same);
drm2d_nonlocality_tool('reset', f);
S = guidata(f);
check('reset leaves rashi_Gy intact', isequal(S.dose.rashi_Gy, saved));
check('reset clears after_Gy', isempty(S.dose.after_Gy));
drm2d_nonlocality_tool('applynl', f);
S = guidata(f);
check('apply after reset reproduces after_Gy', isequal(S.dose.after_Gy, afters{1}));

% --- edge case: region B height 0
drm2d_nonlocality_tool('set', f, 'heightB_mm', 0);
okB = true;
try
    drm2d_nonlocality_tool('calculate', f);
    drm2d_nonlocality_tool('applynl', f);
catch err
    okB = false;
    fprintf('        (K_B = 0 raised: %s)\n', err.message);
end
check('K_B = 0 runs without error', okB);
drm2d_nonlocality_tool('set', f, 'heightB_mm', 40);

% --- edge case: both heights 0 -> calculate refused
drm2d_nonlocality_tool('set', f, 'heightA_mm', 0, 'heightB_mm', 0);
check('both heights 0 disables Calculate', ...
      strcmpi(get(guidata(f).h.btn_calc, 'Enable'), 'off'));
drm2d_nonlocality_tool('set', f, 'heightA_mm', 60, 'heightB_mm', 40);

close(f);
fprintf('  (coarse Calculate took %.1f s)\n', tCalc);

% ================= PLAN2: the five-button workflow (T36 onwards) =============
fprintf('\n  PLAN2 workflow checks\n');
f = apiNew('Visible', 'off');

% T36: both difference buttons start disabled
check('T36 btn_diff/btn_apply disabled before any dose', ...
      strcmpi(get(guidata(f).h.btn_diff,  'Enable'), 'off') && ...
      strcmpi(get(guidata(f).h.btn_apply, 'Enable'), 'off'));

% T37: identity P1 -- the local 2DRM uses exactly the RaShi fluence
P = guidata(f).P;
spots = makeSpots(P);  Nw = rashiWeights(P, spots);
[~, info] = buildPins(P, spots);
gr = makeGrid(max(abs(info.pinned_x_mm)) + P.lateral_margin_mm, ...
              max(abs(info.pinned_y_mm)) + P.lateral_margin_mm, P.lateral_pixel_mm);
FR = fluenceRashi(gr, spots, Nw, P.fwhm0_mm * FWHM2SIG());
Wi = sum(Nw, 2);
C  = derivedCounts(P);
% build F_local the long way: every spot through its OWN pin only
FL = zeros(size(FR));
for i = 1:numel(spots.x_mm)
    if spots.isZoneA(i), KZ = C.K_A; else, KZ = C.K_B; end
    if KZ <= 0, continue; end
    Px = pixelGauss1d(gr.xe_mm, spots.x_mm(i), P.fwhm0_mm * FWHM2SIG());
    Py = pixelGauss1d(gr.ye_mm, spots.y_mm(i), P.fwhm0_mm * FWHM2SIG());
    outer = Px' * Py;
    for k = 1:KZ
        FL(:,:,k+1) = FL(:,:,k+1) + (Wi(i)/KZ) * outer;
    end
end
rel = max(abs(FL(:) - FR(:))) / max(abs(FR(:)));
check('T37 identity P1: F_local == F_R', rel < 1e-12, sprintf('relmax %g', rel));

% T43 order independence + T39 difference-before formula
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('calc2drm',  f);
drm2d_nonlocality_tool('seediff',   f);
S1 = guidata(f);
d1 = S1.dose.diff_pct;
expect = (S1.dose.local_Gy - S1.dose.rashi_Gy) / max(S1.dose.rashi_Gy(:)) * 100;
check('T39 difference-before formula', ...
      max(abs(d1(:) - expect(:))) < 1e-9 * max(abs(expect(:))));
check('T39 diffMode is before', strcmp(S1.dose.diffMode, 'before'));

g = apiNew('Visible', 'off');
drm2d_nonlocality_tool('calc2drm',  g);     % reversed order
drm2d_nonlocality_tool('calcrashi', g);
drm2d_nonlocality_tool('seediff',   g);
check('T43 order independence', isequal(guidata(g).dose.diff_pct, d1));
close(g);

% T38: the local 2DRM differs from RaShi ONLY through lp_M
check('T38 local 2DRM differs from RaShi (material term)', ...
      ~isequal(S1.dose.local_Gy, S1.dose.rashi_Gy) && max(abs(d1(:))) < 25, ...
      sprintf('max |diff| = %.2f %%', max(abs(d1(:)))));

% T41/T42: Apply is idempotent and both originals are immutable
savedR = S1.dose.rashi_Gy;  savedL = S1.dose.local_Gy;
aft = {};
for i = 1:5
    drm2d_nonlocality_tool('applynl', f);
    aft{end+1} = guidata(f).dose.after_Gy;   %#ok<AGROW>
end
S2 = guidata(f);
same = true;  for i = 2:5, same = same && isequal(aft{i}, aft{1}); end
check('T41 after_Gy identical across 5 applies', same);
check('T41 applyCount == 5', S2.applyCount == 5);
check('T42 rashi_Gy bitwise unchanged', isequal(S2.dose.rashi_Gy, savedR));
check('T42 local_Gy bitwise unchanged', isequal(S2.dose.local_Gy, savedL));
check('T39/after: after_Gy == local + nl', ...
      isequal(S2.dose.after_Gy, S2.dose.local_Gy + S2.dose.nl_Gy));
check('T39/after: model applied to LOCAL not RaShi', ...
      ~isequal(S2.dose.after_Gy, S2.dose.rashi_Gy + S2.dose.nl_Gy));
expA = (S2.dose.after_Gy - savedR) / max(savedR(:)) * 100;
check('T39 difference-after formula', ...
      max(abs(S2.dose.diff_pct(:) - expA(:))) < 1e-9 * max(abs(expA(:))));

% T45: Reset clears Apply state but keeps BOTH doses
drm2d_nonlocality_tool('reset', f);
S3 = guidata(f);
check('T45 reset keeps rashi_Gy', isequal(S3.dose.rashi_Gy, savedR));
check('T45 reset keeps local_Gy', isequal(S3.dose.local_Gy, savedL));
check('T45 reset clears nl/after/diff', ...
      isempty(S3.dose.nl_Gy) && isempty(S3.dose.after_Gy) && isempty(S3.dose.diff_pct));
drm2d_nonlocality_tool('reset', f);
check('T45 second reset is a no-op', isequal(guidata(f).dose.rashi_Gy, savedR));

% T44: mixed-geometry guard
drm2d_nonlocality_tool('calcrashi', f);
drm2d_nonlocality_tool('set', f, 'heightB_mm', 20);
drm2d_nonlocality_tool('calc2drm', f);
check('T44 mixed geometry disables See difference', ...
      strcmpi(get(guidata(f).h.btn_diff, 'Enable'), 'off'));
drm2d_nonlocality_tool('set', f, 'heightB_mm', 40);

% T46-T49: Result figure gating
h = apiNew('Visible', 'off');
H0 = drm2d_nonlocality_tool('result', h);
check('T46 Result with no dose -> 2 parameter-only figures', numel(H0) == 2, ...
      sprintf('got %d', numel(H0)));
drm2d_nonlocality_tool('calcrashi', h);
H1 = drm2d_nonlocality_tool('result', h);
check('T47 Result after RaShi only -> still 2', numel(H1) == 2, sprintf('got %d', numel(H1)));
drm2d_nonlocality_tool('calc2drm', h);
H2 = drm2d_nonlocality_tool('result', h);
check('T48 Result after both doses -> 5', numel(H2) == 5, sprintf('got %d', numel(H2)));
drm2d_nonlocality_tool('applynl', h);
H3 = drm2d_nonlocality_tool('result', h);
check('T49 Result after Apply -> 6', numel(H3) == 6, sprintf('got %d', numel(H3)));
% T50: every handle valid, named, with at least one axes
okFig = true;
for i = 1:numel(H3)
    okFig = okFig && ishandle(H3(i)) && ~isempty(get(H3(i), 'Name')) && ...
            ~isempty(findobj(H3(i), 'Type', 'axes'));
end
check('T50 all Result figures valid, named, with axes', okFig);
close([H0(:); H1(:); H2(:); H3(:)]);

% T51/T52/T53: information box
Sh = guidata(h);
txt = get(Sh.h.txt_info, 'String');
if ~iscell(txt), txt = cellstr(txt); end
joined = strjoin(txt(:)', ' | ');
[~, fAx] = fZoneA(Sh.P, Sh.P.spacing_mm/2);
check('T51 info box has the model block', ...
      contains(joined, 'f_A') && contains(joined, 'r_B') && contains(joined, 'sigma'));
check('T51 f_A finite and in (0,1)', isfinite(fAx) && fAx > 0 && fAx < 1, ...
      sprintf('f_A = %g', fAx));
check('T52 info box sum(a_k) reports OK', contains(joined, 'OK'));
check('T53 info box has the dose block', ...
      contains(joined, 'max RaShi') && contains(joined, 'peak |dD|'));
close(h);

% T54: per-zone normalisation differs from the global one for a thin Region B
t = apiNew('Visible', 'off', 'heightB_mm', 10);
drm2d_nonlocality_tool('calcrashi', t);
drm2d_nonlocality_tool('calc2drm',  t);
drm2d_nonlocality_tool('applynl',   t);
St = guidata(t);
gl = max(abs(St.dose.diff_pct(:)));
pz = perZonePeakPct(St, St.P);
check('T54 per-zone vs global normalisation differ (thin Region B)', ...
      isfinite(pz) && pz > gl, sprintf('global %.2f %%, per-zone %.2f %%', gl, pz));
close(t);

% ---------------------------------------------------------------- D1 and D2
% T57: exact_Gy must be stamped and guarded.  Before the fix exact_Gy had no
% parameter stamp, so a stale one survived a geometry change and was silently
% differenced against the new doses (info box showed 52 % for a true ~2.5 %).
% T58: the pin ripple must be measured on (exact - rashi), the only array built
% from a position-labelled fluence.  Measured on the displayed difference it
% returned a discretisation artefact that collapsed 9x on grid refinement.
e = apiNew('Visible', 'off');
drm2d_nonlocality_tool('set', e, 'compareExact', true);   % compute the exact dose
drm2d_nonlocality_tool('calcrashi', e);
drm2d_nonlocality_tool('calc2drm',  e);
drm2d_nonlocality_tool('applynl',   e);
Se = guidata(e);

check('T57 PusedExact stamp exists', isfield(Se.dose, 'PusedExact'));
check('T57 fresh exact dose is stamped', ~isempty(Se.dose.PusedExact));
check('T57 fresh exact dose counts as current', exactIsCurrent(Se));
mvGood = modelVsExactPct(Se);
check('T57 model-vs-exact finite for a current exact dose', isfinite(mvGood), ...
      sprintf('%.3f %%', mvGood));

% D2: the reported ripple must come from (exact - rashi), NOT from diff_pct.
rrGood = pinRippleRms(Se, Se.P);
Rg     = Se.dose.rashi_Gy;
fblk   = round(Se.P.spacing_mm / Se.P.voxel_mm);
oldRip = localRippleOf(Se.dose.diff_pct, Rg, fblk);        % the pre-fix input
newRip = localRippleOf((Se.dose.exact_Gy - Rg)/max(Rg(:))*100, Rg, fblk);
check('T58 ripple is finite with a current exact dose', isfinite(rrGood), ...
      sprintf('%.3f %%', rrGood));
check('T58 ripple matches the exact-RaShi difference', ...
      abs(rrGood - newRip) < 1e-9, sprintf('shown %.4f vs exact-based %.4f', rrGood, newRip));
check('T58 ripple is NOT the diff_pct artefact', ...
      abs(rrGood - oldRip) > 0.1, ...
      sprintf('exact-based %.4f %%, diff_pct artefact %.4f %%', newRip, oldRip));

% A valid exact dose must SURVIVE Reset (the user's no-recompute decision).
drm2d_nonlocality_tool('reset', e);
check('T57 valid exact dose survives Reset', exactIsCurrent(guidata(e)));

% Now make it stale: change the geometry, recalculate WITHOUT ticking exact.
drm2d_nonlocality_tool('set', e, 'compareExact', false);
drm2d_nonlocality_tool('set', e, 'heightB_mm', 20);
drm2d_nonlocality_tool('calcrashi', e);
drm2d_nonlocality_tool('calc2drm',  e);
drm2d_nonlocality_tool('applynl',   e);
Se = guidata(e);

check('T57 stale exact dose is rejected', ~exactIsCurrent(Se));
check('T57 model-vs-exact is NaN when stale', ~isfinite(modelVsExactPct(Se)));
check('T58 ripple is NaN when the exact dose is stale', ~isfinite(pinRippleRms(Se, Se.P)));
infoS = get(Se.h.txt_info, 'String');
joinS = strjoin(cellstr(infoS), ' | ');
check('T57 info box shows "-" for model vs exact when stale', ...
      contains(joinS, 'model vs exact    -'));
check('T58 info box shows "-" for pin ripple when stale', ...
      contains(joinS, 'pin ripple rms    -'));
% fig3_maps must fall back to 2 panels rather than draw from the stale array
Hs = drm2d_nonlocality_tool('result', e);
% the figure Name is descriptive and carries the Python name in brackets
fm = Hs(arrayfun(@(h) contains(get(h, 'Name'), 'fig3_maps'), Hs));
if isempty(fm)
    check('T57 fig3_maps falls back to 2 panels when stale', false, 'figure not produced');
else
    check('T57 fig3_maps falls back to 2 panels when stale', ...
          numel(findobj(fm, 'Type', 'axes')) == 2, ...
          sprintf('got %d axes', numel(findobj(fm, 'Type', 'axes'))));
end
close(Hs(ishandle(Hs)));
close(e);

close(f);

% --- optional: compare against the Python reference
if full
    fprintf('\n  comparing against reference/ref_default.mat ...\n');
    [p2, f2] = compareWithReference('default');
    np = np + p2;  nf = nf + f2;
end

fprintf('--------------------------------\n%d passed, %d failed\n', np, nf);
ok = (nf == 0);
if ok, fprintf('ALL PASSED\n'); else, fprintf('FAILURES PRESENT\n'); end
end


function [np, nf] = compareWithReference(name)
%COMPAREWITHREFERENCE  Check the ported physics against the Python .mat export.
np = 0; nf = 0;
here = fileparts(mfilename('fullpath'));
path_ref = fullfile(here, 'reference', ['ref_' name '.mat']);
if exist(path_ref, 'file') ~= 2
    fprintf('    SKIP: %s not found (run export_reference.py)\n', path_ref);
    return;
end
R = load(path_ref);

P = defaultParams();
P.lateral_pixel_mm = 0.5;                        % high fidelity, matches the export
P.energy_MeVu  = double(R.params.energy_MeVu);
P.heightA_mm   = double(R.K_A);
P.heightB_mm   = double(R.K_B);
P.expand_mode  = strtrim(char(R.params.expand_mode));

    function chk(nm, A, B, tol)
        rel = max(abs(A(:) - B(:))) / max(1e-300, max(abs(B(:))));
        if rel < tol
            np = np + 1;  fprintf('    PASS  %-28s relmax %.3g < %.3g\n', nm, rel, tol);
        else
            nf = nf + 1;  fprintf('    FAIL  %-28s relmax %.3g >= %.3g\n', nm, rel, tol);
        end
    end

[ddd, rng] = loadTables(P);
chk('ddd z',    ddd.z_mm,  R.ddd_z_mm(:),  1e-14);
chk('ddd dedz', ddd.dedz,  R.ddd_dedz(:),  1e-14);
chk('range R0', rangeFromEnergy(rng, P.energy_MeVu), double(R.rng_R0_mm), 1e-12);

lpR = levelProps(P, 'rashi', rng);
chk('lp rashi wepl',      lpR.wepl_mm,      R.lp_rashi.wepl(:),      1e-12);
chk('lp rashi theta_dev', lpR.thetaDev_rad, R.lp_rashi.theta_dev(:), 1e-10);
chk('lp rashi theta_air', lpR.thetaAir_rad, R.lp_rashi.theta_air(:), 1e-10);
lpM = levelProps(P, '2drm', rng);
chk('lp 2drm wepl',       lpM.wepl_mm,      R.lp_2drm.wepl(:),       1e-12);
chk('lp 2drm theta_dev',  lpM.thetaDev_rad, R.lp_2drm.theta_dev(:),  1e-10);

spots = makeSpots(P);
N = rashiWeights(P, spots);
[pins, info] = buildPins(P, spots);
if info.n_pins ~= double(R.pin_count)
    nf = nf + 1;  fprintf('    FAIL  pin count %d vs %d\n', info.n_pins, double(R.pin_count));
else
    np = np + 1;  fprintf('    PASS  pin count %d\n', info.n_pins);
end

halfX = max(abs(info.pinned_x_mm)) + P.lateral_margin_mm;
halfY = max(abs(info.pinned_y_mm)) + P.lateral_margin_mm;
grid  = makeGrid(halfX, halfY, P.lateral_pixel_mm);
sig0  = P.fwhm0_mm * FWHM2SIG();

F_R = fluenceRashi(grid, spots, N, sig0);
% Python F is (K+1, nx, ny); MATLAB F is (nx, ny, K+1) -> permute to compare.
chk('F_R', permute(F_R, [3 1 2]), R.F_R, 1e-10);

W   = sum(N, 2);
F_M = fluence2drm(grid, spots, W, sig0, pins, P.spacing_mm, max(double(R.K_max), 0));
chk('F_M', permute(F_M, [3 1 2]), R.F_M, 1e-10);

zMax = double(R.z_max_mm);
dR = computeDose(P, grid, F_R, lpR, ddd, zMax);
chk('dose RaShi', dR, R.dose_rashi_Gy, 1e-6);
dM = computeDose(P, grid, F_M, lpM, ddd, zMax);
chk('dose 2DRM',  dM, R.dose_2drm_Gy,  1e-6);

% The comparison deliberately uses the SINGLE-x slice (Python analysis.fig_dose_maps),
% not the x-averaged slice the GUI displays, so the display choice cannot affect it.
chk('dose RaShi single-x slice', sliceSingleX(dR, grid.xe_mm), ...
    sliceSingleX(R.dose_rashi_Gy, R.x_edges_mm(:)), 1e-6);

if double(R.nl_valid) == 1
    nlD = predictDeltaDose(P, ddd, rng, 1.0, double(R.nl_half_mm));
    chk('non-locality dD', nlD, R.nl_delta_dose_Gy, 1e-6);
else
    fprintf('    SKIP  non-locality dD (nl_valid = 0: Python value is defective)\n');
end
end
