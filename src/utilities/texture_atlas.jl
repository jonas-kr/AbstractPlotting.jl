using Serialization
using FreeTypeAbstraction: iter_or_array

mutable struct TextureAtlas
    rectangle_packer::GuillotinePacker
    mapping::Dict{Any, Int} # styled glyph to index in sprite_attributes
    index::Int
    data::Matrix{Float16}
    attributes::Vector{Vec4f0}
    scale::Vector{Vec2f0}
    extent::Vector{FontExtent{Float32}}
end

Base.size(atlas::TextureAtlas) = size(atlas.data)

@enum GlyphResolution High Low

const TEXTURE_RESOLUTION = Ref((2048, 2048))
const CACHE_RESOLUTION_PREFIX = Ref("high")
const DOWN_SAMPLE_FACTOR = Ref(50)
const DOWN_SAMPLE_HIGH = 50
const DOWN_SAMPLE_LOW = 30

function size_factor()
    return DOWN_SAMPLE_HIGH / DOWN_SAMPLE_FACTOR[]
end

function set_glyph_resolution!(res::GlyphResolution)
    if res == High
        TEXTURE_RESOLUTION[] = (2048, 2048)
        CACHE_RESOLUTION_PREFIX[] = "high"
        DOWN_SAMPLE_FACTOR[] = DOWN_SAMPLE_HIGH
    else
        TEXTURE_RESOLUTION[] = (1024, 1024)
        CACHE_RESOLUTION_PREFIX[] = "low"
        DOWN_SAMPLE_FACTOR[] = DOWN_SAMPLE_LOW
    end
end


function TextureAtlas(initial_size = TEXTURE_RESOLUTION[])
    return TextureAtlas(
        GuillotinePacker(initial_size...),
        Dict{Any, Int}(),
        1,
        zeros(Float16, initial_size...),
        Vec4f0[],
        Vec2f0[],
        FontExtent{Float64}[]
    )
end

assetpath(files...) = joinpath(@__DIR__, "..", "..", "assets", files...)

begin #basically a singleton for the textureatlas
    # random list of chars we cache
    # basically to make runtests fast, until we figure out a better way to cache
    # newly rendered chars.
    const _tobe_cached = [
        'π','∮','⋅','→','∞','∑','∏','∀','∈','ℝ','⌈','⌉','−','⌊','⌋','α','∧','β','∨','ℕ','⊆','₀',
        '⊂','ℤ','ℚ','ℂ','⊥','≠','≡','≤','≪','⊤','⇒','⇔','₂','⇌','Ω','⌀',
    ]
    function get_cache_path()
        return abspath(
            first(Base.DEPOT_PATH), "makiegallery", ".cache",
            "texture_atlas_$(CACHE_RESOLUTION_PREFIX[])_v2.jls"
        )
    end
    const _default_font = NativeFont[]
    const _alternative_fonts = NativeFont[]

    function defaultfont()
        if isempty(_default_font)
            push!(_default_font, NativeFont(assetpath("fonts", "DejaVuSans.ttf")))
        end
        _default_font[]
    end

    function alternativefonts()
        if isempty(_alternative_fonts)
            alternatives = [
                "DejaVuSans.ttf",
                "NotoSansCJKkr-Regular.otf",
                "NotoSansCuneiform-Regular.ttf",
                "NotoSansSymbols-Regular.ttf",
                "FiraMono-Medium.ttf"
            ]
            for font in alternatives
                push!(_alternative_fonts, NativeFont(assetpath("fonts", font)))
            end
        end
        _alternative_fonts
    end

    function cached_load()
        if isfile(get_cache_path())
            try
                return open(get_cache_path()) do io
                    dict = Serialization.deserialize(io)
                    fields = map(fieldnames(TextureAtlas)) do n
                        v = dict[n]
                        isa(v, Vector) ? copy(v) : v # otherwise there seems to be a problem with resizing
                    end
                    TextureAtlas(fields...)
                end
            catch e
                @info("You can likely ignore the following warning, if you just switched Julia versions for GLVisualize")
                @warn(e)
                rm(get_cache_path())
            end
        end
        atlas = TextureAtlas()
        @info("Caching fonts, this may take a while. Needed only on first run!")
        for c in '\u0000':'\u00ff' #make sure all ascii is mapped linearly
            insert_glyph!(atlas, c, defaultfont())
        end
        to_cache(atlas) # cache it
        return atlas
    end

    function to_cache(atlas)
        if !ispath(dirname(get_cache_path()))
            mkpath(dirname(get_cache_path()))
        end
        open(get_cache_path(), "w") do io
            dict = Dict(map(fieldnames(typeof(atlas))) do name
                name => getfield(atlas, name)
            end)
            Serialization.serialize(io, dict)
        end
    end
    const global_texture_atlas = RefValue{TextureAtlas}()
    function get_texture_atlas()
        if isassigned(global_texture_atlas) && size(global_texture_atlas[]) == TEXTURE_RESOLUTION[]
            global_texture_atlas[]
        else
            global_texture_atlas[] = cached_load() # initialize only on demand
            global_texture_atlas[]
        end
    end

end

function glyph_index!(atlas::TextureAtlas, c::Char, font::NativeFont)
    if FT_Get_Char_Index(font, c) == 0
        for afont in alternativefonts()
            if FT_Get_Char_Index(afont, c) != 0
                font = afont
            end
        end
    end
    if c < '\u00ff' && font == defaultfont() # characters up to '\u00ff'(255), are directly mapped for default font
        return Int(c)+1
    else #others must be looked up, since they're inserted when used first
        return insert_glyph!(atlas, c, font)
    end
end

glyph_scale!(c::Char, scale) = glyph_scale!(get_texture_atlas(), c, defaultfont(), scale)
glyph_uv_width!(c::Char) = glyph_uv_width!(get_texture_atlas(), c, defaultfont())

function glyph_uv_width!(atlas::TextureAtlas, c::Char, font::NativeFont)
    atlas.attributes[glyph_index!(atlas, c, font)]
end

function glyph_scale!(atlas::TextureAtlas, c::Char, font::NativeFont, scale)
    atlas.scale[glyph_index!(atlas, c, font)] .* (scale * 0.02) .* size_factor()
end

function glyph_extent!(atlas::TextureAtlas, c::Char, font::NativeFont)
    atlas.extent[glyph_index!(atlas, c, font)]
end

function bearing(extent)
    Point2f0(
        extent.horizontal_bearing[1],
        -(extent.scale[2] - extent.horizontal_bearing[2])
    )
end

function glyph_bearing!(atlas::TextureAtlas, c::Char, font::NativeFont, scale)
    bearing(atlas.extent[glyph_index!(atlas, c, font)]) .* Point2f0(scale * 0.02) .* size_factor()
end

function glyph_advance!(atlas::TextureAtlas, c::Char, font::NativeFont, scale)
    atlas.extent[glyph_index!(atlas, c, font)].advance .* (scale * 0.02) .* size_factor()
end

function insert_glyph!(atlas::TextureAtlas, glyph::Char, font::NativeFont)
    return get!(atlas.mapping, (glyph, font)) do
        uv, extent, width_nopadd, pad, reversed = render(atlas, glyph, font)
        tex_size = Vec2f0(size(atlas.data))
        # padd one additional pixel
        x, y = minimum(uv) ./ tex_size # use normalized texture coordinates
        xmax, ymax = maximum(uv) ./ tex_size
        if reversed
            w, h = widths(uv)
            scale = (h, w)
            uv_offset_width = Vec4f0(ymax, x, y, xmax)
        else
            scale = widths(uv)
            uv_offset_width = Vec4f0(x, y, xmax, ymax)
        end
        i = atlas.index
        push!(atlas.attributes, uv_offset_width)
        push!(atlas.scale, scale)
        push!(atlas.extent, extent)
        atlas.index = i + 1
        return i
    end
end

function sdistancefield(img, downsample = 8, pad = 8*downsample)
    w, h = size(img)
    wpad = 0; hpad = 0;
    while w % downsample != 0
        w += 1
    end
    while h % downsample != 0
        h += 1
    end
    w, h = w + 2pad, h + 2pad #pad this, to avoid cuttoffs

    in_or_out = Matrix{Bool}(undef, w, h)
    @inbounds for i in 1:w, j in 1:h
        x, y = i - pad, j - pad
        in_or_out[i,j] = checkbounds(Bool, img, x, y) && img[x,y] > 0.5 * 255
    end
    yres, xres = div(w, downsample), div(h, downsample)
    sd = sdf(in_or_out, xres, yres)
    return Float16.(sd)
end

const font_render_callbacks = Function[]

function font_render_callback!(f)
    push!(font_render_callbacks, f)
end

function remove_font_render_callback!(f)
    filter!(f2-> f2 != f, font_render_callbacks)
end

function render(atlas::TextureAtlas, glyph::Char, font, downsample = 5, pad = 8)
    if glyph == '\n' # don't render  newline
        glyph = ' '
    end
    DF = DOWN_SAMPLE_FACTOR[]
    bitmap, extent = renderface(font, glyph, DF * downsample)
    sd = sdistancefield(bitmap, downsample, downsample * pad)
    sd = sd ./ downsample
    rect = Rect(0, 0, size(sd)...)
    uv = push!(atlas.rectangle_packer, rect) #find out where to place the rectangle
    uv == nothing && error("texture atlas is too small. Resizing not implemented yet. Please file an issue at GLVisualize if you encounter this") #TODO resize surface
    extent = extent ./ Vec2f0(downsample)
    reversed = Vec(size(sd)) != widths(uv) # did the packer flip the rect?
    if reversed
        println(glyph, " ", widths(uv), " ", size(sd))
        sd = rotr90(sd)
    end
    atlas.data[uv] = sd
    for f in font_render_callbacks
        f(sd, uv)
    end
    return uv, extent, Vec2f0(size(bitmap)) ./ (downsample), pad, reversed
end

make_iter(x) = repeated(x)
make_iter(x::AbstractArray) = x

function get_iter(defaultfunc, dictlike, key)
    make_iter(get(defaultfunc, dictlike, key))
end

function getposition(text, text2, fonts, scales, start_pos)
    calc_position(text2, start_pos, scales, fonts, text.text.atlas)
end
function getoffsets(text, text2, fonts, scales)
    calc_offset(text2, scales, fonts, text.text.atlas)
end


function calc_position(
        last_pos, start_pos,
        atlas, glyph, font,
        scale, lineheight = 1.5
    )
    advance_x, advance_y = glyph_advance!(atlas, glyph, font, scale)
    if isnewline(glyph)
        return Point2f0(start_pos[1], last_pos[2] - advance_y * lineheight) #reset to startx
    else
        return last_pos + Point2f0(advance_x, 0)
    end
end

function calc_position(glyphs, start_pos, scales, fonts, atlas)
    positions = zeros(Point2f0, length(glyphs))
    last_pos  = Point2f0(start_pos)
    s, f = iter_or_array(scales), iter_or_array(fonts)
    c1 = first(glyphs)
    for (i, (c2, scale, font)) in enumerate(zip(glyphs, s, f))
        c2 == '\r' && continue # stupid windows!
        b = glyph_bearing!(atlas, c2, font, scale)
        positions[i] = last_pos .+ b
        last_pos = calc_position(last_pos, start_pos, atlas, c2, font, scale)
    end
    return positions
end

function calc_offset(glyphs, scales, fonts, atlas)
    offsets = fill(Point2f0(0.0), length(glyphs))
    s, f = iter_or_array(scales), iter_or_array(fonts)
    c1 = first(glyphs)
    for (i, (c2, scale, font)) in enumerate(zip(glyphs, s, f))
        c2 == '\r' && continue # stupid windows!
        offsets[i] = Point2f0(glyph_bearing!(atlas, c2, font, scale))
        c1 = c2
    end
    return offsets # bearing is the glyph offset
end

isnewline(x) = x == '\n'
