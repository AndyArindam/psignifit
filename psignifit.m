function result=psignifit(data,options)
% main function for fitting psychometric functions
%function result=psignifit(data,options)
% This function is the user interface for fitting psychometric functions to
% data.
%
% pass your data in the n x 3 matrix of the form:
%       [x-value, number correct, number of trials]
%
% options should be a 1x1 struct in which you set the options for your fit.
% You can find a full overview over the options in demo002
%
% The result of this function is a struct, which contains all information
% the program produced for your fit. You can pass this as whole to all
% further processing function provided with psignifit. Especially to the
% plot and test functions.
% You can find an explanation for all fields of the result in demo003, an
% introduction to our plotting functions in demo004 and to the test
% functions in demo005
%
%
% To get an introduction to basic useage start with demo001
%




%% input parsing

if ~exist('options','var'),                  options=struct;                    end
if ~isfield(options,'sigmoidName'),          options.sigmoidName    = 'norm';   end
if ~isfield(options,'expType'),              options.expType        = 'YesNo';  end
if ~isfield(options,'estimateType'),         options.estimateType   = 'mean';   end
if ~isfield(options,'confP'),                options.confP          = .95;      end
if ~isfield(options,'instantPlot'),          options.instantPlot    = 0;        end
if ~isfield(options,'setBordersType'),       options.setBordersType = 0;        end
if ~isfield(options,'maxBorderValue'),       options.maxBorderValue = exp(-7);  end
if ~isfield(options,'moveBorders'),          options.moveBorders    = 1;        end
if ~isfield(options,'dynamicGrid'),          options.dynamicGrid    = 0;        end
if ~isfield(options,'widthalpha'),           options.widthalpha     = .05;      end
if ~isfield(options,'CImethod'),             options.CImethod       = 'stripes';end
if ~isfield(options,'gridSetType'),          options.gridSetType    = 'cumDist';end
if ~isfield(options,'fixedPars'),            options.fixedPars      = nan(5,1); end
if ~isfield(options,'nblocks'),              options.nblocks        = 30;       end
if ~isfield(options,'useGPU'),               options.useGPU         = 0;        end
if ~isfield(options,'poolMaxGap'),           options.poolMaxGap     = 1;        end
if ~isfield(options,'poolMaxLength'),        options.poolMaxLength  = 20;       end
if ~isfield(options,'poolxTol'),             options.poolxTol       = 0;        end
if ~isfield(options,'betaPrior'),            options.betaPrior      = 20;       end
if ~isfield(options,'verbose'),              options.verbose        = 0;        end





if strcmp(options.expType,'2AFC'),           options.expType        = 'nAFC';
    options.expN           = 2;        end

if strcmp(options.expType,'nAFC') && ~isfield(options,'expN');
    error('For nAFC experiments please also pass the number of alternatives (options.expN)'); end

switch options.expType
    case 'YesNo'
        if ~isfield(options,'stepN'),   options.stepN   = [40,40,20,20,20];  end
        if ~isfield(options,'mbStepN'), options.mbStepN = [25,20,10,10,15];  end
    case 'nAFC'
        if ~isfield(options,'stepN'),   options.stepN   = [40,40,20,1,20];   end
        if ~isfield(options,'mbStepN'), options.mbStepN = [30,30,10,1,20];   end
    case 'equalAsymptote'
        if ~isfield(options,'stepN'),   options.stepN   = [40,40,20,1,20];   end
        if ~isfield(options,'mbStepN'), options.mbStepN = [30,30,10,1,20];   end
    otherwise
        error('You specified an illegal experiment type')
end

assert(max(data(:,1)) > min(data(:,1)) , 'Your data does not have variance on the x-axis! This makes fitting impossible')

% check gpuOptions
if options.useGPU && ~gpuDeviceCount
    warning('You wanted to use your GPU but MATLAB does not recognize any useable GPU. We thus disabled GPU useage')
    options.useGPU=0;
end
if options.useGPU
    gpuDevice(options.useGPU);
end


% log space sigmoids
% we fit these functions with a log transformed physical axis
% This is because it makes the paramterization easier and also the priors
% fit our expectations better then.
% The flag is needed for the setting of the parameter bounds in setBorders

if any(strcmpi(options.sigmoidName,{'Weibull','logn'}))
    options.logspace = 1;
    assert(min(data(:,1)) > 0, 'The sigmoid you specified is not defined for negative data points!');
else
    options.logspace=0;
end

% add priors
if ~isfield(options,'priors')
    options.priors         = getStandardPriors(data,options);
else 
    if iscell(options.priors)
        priors = getStandardPriors(data,options);
        for ipar = 1:5
            if isa(options.priors{ipar},'function_handle')
                % use the provided prior
            else
                options.priors{ipar} = priors{ipar};
            end
        end
    else
        error('if you provide your own priors it should be a cell array of function handles')
    end
end

% for dynamic grid setting
if options.dynamicGrid && ~isfield(options,'GridSetEval'),   options.GridSetEval   = 10000; end
if options.dynamicGrid && ~isfield(options,'UniformWeight'), options.UniformWeight = 1;    end



%% initialize

% pool data if necessary
% -> more than options.nblocks blocks or only 1 trial per block
if max(data(:, 3)) == 1 || size(data, 1) > options.nblocks
    warning('We pooled your data, to avoid problems with n=1 blocks or to save time fitting because you have a lot of blocks\n You can force acceptence of your blocks by increasing options.nblocks');
    data = poolData(data,options);
    options.nblocks = size(data, 1);
else
    options.nblocks = size(data, 1);
end

% create function handle to the sigmoid
options.sigmoidHandle = getSigmoidHandle(options);

% borders of integration
if ~isfield('options', 'borders')
    options.borders = setBorders(data,options);
    options.borders(~isnan(options.fixedPars),1) = options.fixedPars(~isnan(options.fixedPars)); %fix parameter values
    options.borders(~isnan(options.fixedPars),2) = options.fixedPars(~isnan(options.fixedPars)); %fix parameter values
end
if options.moveBorders
    options.borders = moveBorders(data,options);
end



%% core

result = psignifitCore(data, options);


%% after processing

%check that the marginals go to nearly 0 at the borders of the grid
if options.verbose > -5
    if result.marginals{1}(1).* result.marginalsW{1}(1) > .001
        warning('psignifit:borderWarning',...
           ['The marginal for the threshold is not near 0 at the lower border\n',...
            'This indicates that your data is not fully sufficient to exclude much lower thresholds.\n',...
            'Refer to the paper or the manual for more info on this topic'])
    end
    if result.marginals{1}(end).* result.marginalsW{1}(end) > .001
        warning('psignifit:borderWarning',...
           ['The marginal for the threshold is not near 0 at the upper border\n',...
            'This indicates that your data is not sufficient to exclude much higher thresholds.\n',...
            'Refer to the paper or the manual for more info on this topic'])
    end
    if result.marginals{2}(1).* result.marginalsW{2}(1) > .001
        warning('psignifit:borderWarning',...
           ['The marginal for the width is not near 0 at the lower border\n',...
            'This indicates that your data is not sufficient to exclude much lower widths.\n',...
            'Refer to the paper or the manual for more info on this topic'])
    end
    if result.marginals{2}(end).* result.marginalsW{2}(end) > .001
        warning('psignifit:borderWarning',...
           ['The marginal for the width is not near 0 at the lower border\n',...
            'This indicates that your data is not sufficient to exclude much higher widths.\n',...
            'Refer to the paper or the manual for more info on this topic'])
    end
end


result.timestamp = datestr(now);

if options.instantPlot
    plotPsych(result);
    plotBayes(result);
end

