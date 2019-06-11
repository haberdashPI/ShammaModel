using AxisArrays
using FFTW

export rates, scales, nrates, nscales, default_rates, default_scales,
  cortical, cycoct, co, scalefilter, ratefilter

# re-express the spectral and cortical dimensions to have meta data specific to
# an axis and then make it possible to add an axis to an existing array (maybe
# have a flag to allow multiple axes of the same type)

@dimension Sc "Sc" Scale
@refunit cycoct "cyc/oct" CyclesPerOct Sc false

# NOTE: the `low` and `high` fields are used to determine which filters should
# be low- and high-pass, rather than band-pass
struct ScaleAxis
  low::typeof(1.0cycoct)
  high::typeof(1.0cycoct)
end

struct RateAxis
  low::typeof(1.0Hz)
  high::typeof(1.0Hz)
end

cortical_progress(n) = Progress(desc="Cortical Model: ",n)

rates(x::MetaUnion{AxisArray}) =
  axisvalues(AxisArrays.axes(x,Axis{:rate}))[1]
nrates(x) = length(rates(x))

scales(x::MetaUnion{AxisArray}) =
  axisvalues(AxisArrays.axes(x,Axis{:scale}))[1]
nscales(x) = length(scales(x))

const default_rates = sort([-2 .^ (1:0.5:5); 2 .^ (1:0.5:5)]).*Hz
const default_scales = (2 .^ (-2:0.5:3)).*cycoct
const spect_rate = 24

# cortical responses of rates 
ascycoct(x) = x*cycoct
ascycoct(x::Quantity) = uconvert(cycoct,x)

abstract type CorticalFilter
end
abstract type CorticalFilterInv
end

struct TimeRateFilter <: CorticalFilter
  data::Vector{typeof(1.0Hz)}
  bandonly::Bool
  axis::Symbol
end
axisname(x::TimeRateFilter) = x.axis
Base.length(x::TimeRateFilter) = length(x.data)

function ratefilter(rates=default_rates;bandonly=true,axis=:rate)
  if axis != :rate && !occursin("rate",string(axis))
    error("Rate axis name `$axis` must contain the word 'rate'.")
  end
  TimeRateFilter(rates,bandonly,axis)
end
list_filters()

function DSP.filt(filter::CorticalFilter,y::MetaAxisArray; progressbar=true, 
                  progress=progressbar ? 
                    cortical_progress(length(filter)) : nothing)
  @assert all(in(axisnames(y)),(:time,:freq))
  if any(in(axisnames(filter)),y)
    ax = first(filter(in(axisnames(filter)),y))
    error("Input already has an axis named `$ax`. If you intended ",
          "to add a new dimension, you will have to change the name of the ",
          "axis. When you define the filter you can specify the axis name ",
          "using the `axis` keyword argument.")
  end

  firs = map(ax -> FIRFiltering(y,Axis{ax}),axisnames(filter))
  cr = initfilter(y,filter)
  for (I,H) in enumerate(rate_filters(fir,cr,rates.axis))
    cr[I] = view(apply(fir,H),Base.axes(y)...)
    next!(progress)
  end

  cr
end

# inverse of rates
struct TimeRateFilterInv
  rates::TimeRateFilter
  norm::Float64
end
axisname(x::TimeRateFilterInv) = axisname(x.rates)
Base.inv(rates::TimeRateFilter;norm=0.9) = TimeRateFilterInv(rates,norm)
list_filters(z_cum,cr,rateinv::TimeRateFilterInv) =
  rate_filters(z_cum,cr,axisname(rateinv),use_conj=true)

function DSP.filt(rateinv::TimeRateFilterInv,cr::MetaAxisArray,progressbar=true)
  @assert rateinv.rates.axis in axisnames(cr)
  z_cum = FFTCum(cr,rateinv.rates.axis)

  progress = progressbar ? cortical_progress(nrates(cr)) : nothing
  for (ri,HR) in enumerate(rate_filters(z_cum,cr,rateinv.rates.axis,use_conj=true))
    addfft!(z_cum,cr[Axis{rateinv.rates.axis}(ri)],HR)
    next!(progress)
  end

  MetaAxisArray(removeaxes(getmeta(cr),rateinv.rates.axis),
    normalize!(z_cum,cr,rateinv.norm))
end

# cortical responses of scales
vecperm(x::AbstractVector,n) = reshape(x,fill(1,n-1)...,:)
struct FreqScaleFilter <: CorticalFilter
  data::Vector{typeof(1.0cycoct)}
  bandonly::Bool
  axis::Symbol
end
axisname(x::FreqScaleFilter) = x.axis

function scalefilter(scales=default_scales;bandonly=true,axis=:scale)
  if axis != :scale && !occursin("scale",string(axis))
    error("Scale axis name `$axis` must contain the word 'scale'.")
  end
  FreqScaleFilter(scales,bandonly,axis)
end

function DSP.filt(scales::FreqScaleFilter,y::MetaAxisArray; progressbar=true, 
                   progress=progressbar ? 
                     cortical_progress(length(scales.data)) : nothing)
  @assert :freq in axisnames(y)

  if scales.axis in axisnames(y)
    error("Input already has an axis named `$(scales.axis)`. If you intended ",
          "to add a second rate dimension, change the `axis` keyword argument ",
          "of `scalefilter` to a different value to create a second rate axis.")
  end

  fir = FIRFiltering(y,Axis{:freq})

  cs = initscales(y,scales)
  for (si,HS) in enumerate(scale_filters(fir,cs,scales.axis))
    z = apply(fir,conj.(vecperm([HS; zero(HS)],ndims(y))))
    cs[Axis{scales.axis}(si)] = view(z,Base.axes(y)...)
    next!(progress)
  end

  cs
end

# inverse of scales

struct FreqScaleFilterInv
  scales::FreqScaleFilter
  norm::Float64
end
axisname(x::FreqScaleFilterInv) = axisname(x.scales)
Base.inv(scales::FreqScaleFilter;norm=0.9) = FreqScaleFilterInv(scales,norm)
list_filters(z_cum,cr,scaleinv::FreqScaleFilterInv) =
  scale_filters(z_cum,cr,axisname(scaleinv))

function DSP.filt(scaleinv::FreqScaleFilterInv,cr::MetaAxisArray,progressbar=true)
  @assert axisname(scales) in axisnames(cr)
 
  z_cum = FFTCum(cr,axisnames(scaleinv))

  progress = progressbar ? cortical_progress(nscales(cr)) : nothing
  for (si,HS) in enumerate(list_filters(z_cum,cr,scaleinv))
    addfft!(z_cum,cr[Axis{axisname(scaleinv)}(si)],[HS; zero(HS)]')
    next!(progress)
  end
  MetaAxisArray(removeaxes(getmeta(cr),axisname(scaleinv)),
    normalize!(z_cum,cr,scaleinv.norm))
end

struct ScaleRateFilter
  scales::FreqScaleFilter
  rates::TimeRateFilter
end

function cortical(scales=default_scales,rates=default_rates;bandonly=true,
    axes=(:scale,:rate))

    ScaleRateFilter(scalefilter(scales,bandonly=bandonly,axis=axes[1]),
                    ratefilter(rates,bandonly=bandonly,axis=axes[2]))
end
cortical(scales::FreqScaleFilter,rates::TimeRateFilter) = 
  ScaleRateFilter(scales,rates)

function DSP.filt(composed::ComposedFilter,cr::MetaAxisArray,progresbar=true)
  for filter in composed.data
    cr = filt(filter,cr,progressbar)
  end
  cr
end

struct CorticalFilterInv
  scales::FreqScaleFilterInv
  rates::TimeRateFilterInv
end
Base.inv(cf::ScaleRateFilter) = CorticalFilterInv(inv(cf.scales),inv(cf.rates))
AxisArrays.axisnames(x::CorticalFilterInv) =
  (axisname(x.scales),axisname(x.rates))

function DSP.filt(cinv::CorticalFilterInv,cr::MetaAxisArray,progressbar=true)
  z_cum = FFTCum(cr,axisnames(cinv))

  filters = list_filters(z_cum,cr,cinv)
  progress = progressbar ?  cortical_progress(length(filters)) : nothing

  inner_dims = size(cr)[2:end-1]
  if length(inner_dims) != length(compinv.c.data)
    error("When computing the inverse you must invert all dimensions; partial "*
      "inverses are not yet supported.")
  end

  for (I,filter) in zip(CartesianIndices(inner_dims),filters)
    addfft!(z_cum,cr[:,I,:],filter)
    next!(progress)
  end
  MetaAxisArray(removeaxes(getmeta(cr),axisname.(compinv.c.data)...),
    normalize!(z_cum))
end

function list_filters(z_cum,cr,cf::CorticalFilterInv)
  (CartesianIndex(i,j), HR.*[HS; zero(HS)]' 
   for (i,HR) in list_filters(z_cum,cr,cf.rates)
   for (j,HS) in list_filters(z_cum,cr,cf.scales))
end

################################################################################
# private helper functions

function find_fft_dims(y)
  @assert axisdim(y,Axis{:freq}) == ndims(y)
  @assert axisdim(y,Axis{:time}) == 1
  find_fft_dims(size(y))
end
find_fft_dims(y::NTuple{N,Int}) where {N} =
  (nextprod([2,3,5],y[1]),y[2:end-1]...,nextprod([2,3,5],y[end]))

struct FIRFiltering{T,N}
  Y::Array{T,N}
  plan
end

function FIRFiltering(y,axis)
  dims = map(AxisArrays.axes(y)) do ax
    if AxisArrays.axes(y,axis) == ax
      2nextprod([2,3,5],length(ax))
    else
      length(ax)
    end
  end

  along = axisdim(y,axis)
  Y = fft(pad(y,dims),along)
  FIRFiltering(Y,plan_ifft(Y,along))
end
apply(fir::FIRFiltering,H) = fir.plan * (fir.Y .* H)
Base.size(x::FIRFiltering,i...) = size(x.Y,i...)
Base.ndims(x::FIRFiltering) = ndims(x.Y)

initfilter(y,cortical::ScaleRateFilter) = 
  initfilter(y,cortical.rates,initfilter(y,cortical.scales))

initfilter(y,rates::TimeRateFilter) = 
  initfilter(y,rates.data,rates.axis,rates.bandonly)
function initfilter(y,rates::TimeRateFilter,rateax=:rate,bandonly=false)
  rates = sort(rates)
  r = Axis{rateax}(rates)
  ax = AxisArrays.axes(y)
  newax = ax[1],r,ax[2:end]...

  axar = AxisArray(zeros(complex(eltype(y)),length.(newax)...),newax...)
  arates = sort!(unique!(abs.(rates)))
  rate_axis = bandonly ? 
     RateAxis(-Inf*Hz,Inf*Hz) : RateAxis(first(arates),last(arates))
  axis_meta = addaxes(getmeta(y);Dict(rateax => rate_axis)...)
  MetaAxisArray(axis_meta,axar)
end

initfilter(y,scales::FreqScaleFilter) = 
  initfilter(y,scales.data,scales.axis,scales.bandonly)
function initfilter(y,scales::FreqScaleFilter,scaleax=:scale,bandonly=false)
  scales = sort(scales)
  s = Axis{scaleax}(scales)
  ax = AxisArrays.axes(y)
  newax = ax[1:end-1]...,s,ax[end]

  axar = AxisArray(zeros(complex(eltype(y)),length.(newax)...),newax...)
  scale_axis = bandonly ? 
    ScaleAxis(-Inf*cycoct,Inf*cycoct) :
    ScaleAxis(first(scales),last(scales))
  axis_meta = addaxes(getmeta(y);Dict(scaleax => scale_axis)...)
  MetaAxisArray(axis_meta,axar)
end

# TODO: do this for rates as well
reshape_for(v::Array{T,3},cr::AxisArray{T,3}) where T = v
reshape_for(v::Array{T,4},cr::AxisArray{T,4}) where T = v
reshape_for(v::Array{T,3},cr::AxisArray{T,4}) where T =
    reshape(v,ntimes(cr),1,nfrequencies(cr))

# keeps track of cumulative sum of FIR filters
# in frequency-space so we can readily normalize the result.
struct FFTCum{T,P,N,M,Ax}
  z::Array{Complex{T},N}
  z_cum::Array{Complex{T},M}
  h_cum::Array{T,M}
  nfrequencies::Int
  ntimes::Int
  plan::P
  axes::Ax
end

# TODO: working on generalizing FFTCum to working
# for any number of scale and rate axes
function withoutdim(dims,without)
  dims[1:without-1]...,dims[without+1:end]...
end

function FFTCum(cr::MetaAxisArray,withoutaxes)
  dims = find_fft_dims((size(cr,1),size(cr,ndims(cr))))
  mult = fill(ndims(cr),1)
  mult[1] += any(ax -> startswith(string(ax),"scale"),withoutaxes)
  mult[end] += any(ax -> startswith(string(ax),"rate"),withoutaxes)
  z = zeros(eltype(cr),(dims .* mult)...)

  cumsize = (size(z,1),size(z,2))
  z_cum = zeros(eltype(z),cumsize)
  h_cum = zeros(real(eltype(z)),cumsize)
  plan = plan_fft(z)
  FFTCum(z,z_cum,h_cum,nfrequencies(cr),ntimes(cr),plan)
end

Base.size(x::FFTCum,i...) = size(x.z_cum,i...)
Base.ndims(x::FFTCum) = ndims(x.z_cum)

function addfft!(x::FFTCum,cr,h)
  @assert x.nfrequencies == nfrequencies(cr)
  @assert x.ntimes == ntimes(cr)

  x.z[1:ntimes(cr),1:nfrequencies(cr)] = cr[1:ntimes(cr),1:nfrequencies(cr)]
  Z = x.plan * x.z
  x.h_cum .+= abs2.(h)
  x.z_cum .+= h .* Z

  x
end

function normalize!(x::FFTCum,cr,norm)
  x.h_cum[:,1] .*= 2
  old_sum = sum(x.h_cum[:,nfrequencies(cr)])
  x.h_cum .= norm.*x.h_cum .+ (1 .- norm).*maximum(x.h_cum)
  x.h_cum .*= old_sum ./ sum(view(x.h_cum,:,nfrequencies(cr)))
  x.z_cum ./= x.h_cum

  spectc = view((x.plan \ x.z_cum),1:ntimes(cr),1:nfrequencies(cr))
  max.(real.(2 .* spectc),0)
end

pad(x,lens) = pad(x,lens...)
function pad(x,lens::T...) where T <: Number
  @assert all(size(x) .<= lens)
  y = zeros(eltype(x),lens)
  y[Base.axes(x)...] = x
  y
end

# transforms a bandpass frequency response into either a high or low pass
# response (or leaves it untouched)
function askind(H,len,maxi,kind,nonorm)
  if kind == :band
    H
  else
    old_sum = sum(H)
    if kind == :low
      H[1:maxi-1] .= 1
    elseif kind == :high
      H[maxi+1:len] .= 1
    else
      error("Unexpected filter kind '$kind'.")
    end
    if !nonorm
      H .= H ./ sum(H) .* old_sum
    end

    H
  end
end

function scale_filters(Y,x,scaleax)
  N_f = size(Y,ndims(Y)) >> 1
  scaleparam = getproperty(x,scaleax)
  map(scales(x)) do scale
	  scale_filter(ustrip(uconvert(cycoct,scale)), N_f, spect_rate,
                 scale <= scaleparam.low ? :low : 
                 scale < scaleparam.high ? :band : :high)
  end
end

# create the frequency-scale filter (filter along spectral axis)
function scale_filter(scale,len,ts,kind)
  f2 = ((0:len-1)./len.*ts ./ 2 ./ abs(scale)).^2
  H = f2 .* exp.(1 .- f2)

  askind(H,len,argmax(H),kind,false)
end

function rate_filters(Y,x,rateax;use_conj=false)
  N_t = size(Y,1) >> 1
  rateparam = getproperty(x,rateax)

  map(rates(x)) do rate
    rate_filter(ustrip(uconvert(Hz,rate)), N_t, x.time.Δ,
                abs(rate) <= rateparam.low ? :low :
                abs(rate) < rateparam.high ? :band : :high,use_conj)
  end
end

# create the temporal-rate filter (filter along temporal axis)
function rate_filter(rate,len,Δt,kind,use_conj=false,return_partial=false)
  t = (0:len-1)*ustrip(uconvert(s,Δt))*abs(rate)
  h = @. sin(2π*t) * t^2 * exp(-3.5t)
  h .-= mean(h)

  H0 = view(fft(pad(h,2len)),1:len)
  A = angle.(H0)
  H = abs.(H0)

  maxH,maxi = findmax(H)
  H ./= maxH
  HR = askind(H,len,maxi,kind,true) .* exp.(A*im)

  if use_conj
    HR = conj.(HR)
  end

  if rate >= 0
    HR = pad(HR,2length(HR))
	else
    HR = pad(HR,2length(HR))
		HR[2:end] .= conj.(reverse(HR[2:end]))
		HR[len+1] = abs(HR[len+2])
	end

  if return_partial
    HR,h
  else
    HR
  end
end
