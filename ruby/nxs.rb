# frozen_string_literal: true
# NXS Reader — .nxb parser (Ruby 3.x, stdlib only).
#
# Implements Nexus Standard v1.0 binary wire format.
#
# Usage:
#   buf = File.binread("data.nxb")
#   reader = Nxs::Reader.new(buf)
#   reader.record_count          # => Integer
#   reader.keys                  # => Array<String>
#   obj = reader.record(42)      # => Nxs::Object
#   obj.get_str("username")      # => String | nil
#   obj.get_i64("id")            # => Integer | nil
#   obj.get_f64("score")         # => Float | nil
#   obj.get_bool("active")       # => true/false | nil
#   reader.sum_f64("score")      # => Float
#   reader.min_f64("score")      # => Float | nil
#   reader.max_f64("score")      # => Float | nil
#   reader.sum_i64("id")         # => Integer

module Nxs
  MAGIC_FILE   = 0x4E585342  # NXSB
  MAGIC_OBJ    = 0x4E58534F  # NXSO
  MAGIC_FOOTER = 0x2153584E  # NXS!
  FLAG_SCHEMA  = 0x0002

  class NxsError < StandardError
    attr_reader :code
    def initialize(code, msg)
      super("#{code}: #{msg}")
      @code = code
    end
  end

  # ── Reader ──────────────────────────────────────────────────────────────────

  class Reader
    attr_reader :keys, :record_count

    def initialize(bytes)
      @data = bytes.b   # force binary encoding
      sz = @data.bytesize
      raise NxsError.new("ERR_OUT_OF_BOUNDS", "file too small") if sz < 32

      magic = @data.unpack1("L<")
      raise NxsError.new("ERR_BAD_MAGIC", "expected NXSB, got 0x#{magic.to_s(16)}") if magic != MAGIC_FILE

      footer = @data.unpack1("@#{sz - 4}L<")
      raise NxsError.new("ERR_BAD_MAGIC", "footer magic mismatch") if footer != MAGIC_FOOTER

      # Preamble: Version(2) + Flags(2) + DictHash(8) + TailPtr(8) + Reserved(8)
      @flags    = @data.unpack1("@6 S<")
      @tail_ptr = @data.unpack1("@16 Q<")

      @dict_hash = @data.unpack1("@8 Q<")

      # Schema (when Flags bit 1 set)
      @keys       = []
      @key_sigils = []
      @key_index  = {}
      if @flags & FLAG_SCHEMA != 0
        schema_end = read_schema(32)
        computed = murmur3_64(@data[32...schema_end].bytes)
        raise NxsError.new("ERR_DICT_MISMATCH", "schema hash mismatch") if computed != @dict_hash
      end

      # Tail-index: u32 EntryCount followed by records
      @record_count = @data.unpack1("@#{@tail_ptr}L<")
      @tail_start   = @tail_ptr + 4
    end

    # O(1) record lookup — reads one 10-byte tail-index entry.
    def record(i)
      unless i >= 0 && i < @record_count
        raise NxsError.new("ERR_OUT_OF_BOUNDS", "record #{i} out of [0, #{@record_count})")
      end
      # Each tail-index entry: u16 KeyID + u64 AbsoluteOffset = 10 bytes
      abs_offset = @data.unpack1("@#{@tail_start + i * 10 + 2}Q<")
      Object.new(self, abs_offset)
    end

    # Tight allocation-free sum loop.
    def sum_f64(key)
      slot = @key_index[key]
      raise NxsError.new("ERR_OUT_OF_BOUNDS", "key '#{key}' not in schema") unless slot
      data = @data
      tail = @tail_start
      n    = @record_count
      sum  = 0.0
      i = 0
      while i < n
        abs = data.unpack1("@#{tail + i * 10 + 2}Q<")
        off = _scan_offset(data, abs, slot)
        sum += data.unpack1("@#{off}E") if off
        i += 1
      end
      sum
    end

    def min_f64(key)
      slot = @key_index[key]
      raise NxsError.new("ERR_OUT_OF_BOUNDS", "key '#{key}' not in schema") unless slot
      data = @data
      tail = @tail_start
      n    = @record_count
      min  = nil
      i = 0
      while i < n
        abs = data.unpack1("@#{tail + i * 10 + 2}Q<")
        off = _scan_offset(data, abs, slot)
        if off
          v   = data.unpack1("@#{off}E")
          min = v if min.nil? || v < min
        end
        i += 1
      end
      min
    end

    def max_f64(key)
      slot = @key_index[key]
      raise NxsError.new("ERR_OUT_OF_BOUNDS", "key '#{key}' not in schema") unless slot
      data = @data
      tail = @tail_start
      n    = @record_count
      max  = nil
      i = 0
      while i < n
        abs = data.unpack1("@#{tail + i * 10 + 2}Q<")
        off = _scan_offset(data, abs, slot)
        if off
          v   = data.unpack1("@#{off}E")
          max = v if max.nil? || v > max
        end
        i += 1
      end
      max
    end

    def sum_i64(key)
      slot = @key_index[key]
      raise NxsError.new("ERR_OUT_OF_BOUNDS", "key '#{key}' not in schema") unless slot
      data = @data
      tail = @tail_start
      n    = @record_count
      sum  = 0
      i = 0
      while i < n
        abs = data.unpack1("@#{tail + i * 10 + 2}Q<")
        off = _scan_offset(data, abs, slot)
        sum += data.unpack1("@#{off}q<") if off
        i += 1
      end
      sum
    end

    # Expose internals for Object
    attr_reader :data, :key_index

    # Walk the LEB128 bitmask from obj_offset+8, count set bits before `slot`,
    # and return the absolute byte offset of the field value (or nil if absent).
    # Used by both bulk reducers and NxsObject.
    def _scan_offset(data, obj_offset, slot)
      p = obj_offset + 8   # skip Magic(4) + Length(4)
      cur   = 0
      t_idx = 0

      loop do
        b    = data.getbyte(p)
        p   += 1
        bits = b & 0x7F
        7.times do |i|
          if cur == slot
            # field absent if bit is 0
            return nil if (bits >> i) & 1 == 0
            # p already past this bitmask byte; drain remaining continuation bytes
            while (b & 0x80) != 0
              b = data.getbyte(p)
              p += 1
            end
            # p now points to the offset table
            rel = data.unpack1("@#{p + t_idx * 2}S<")
            return obj_offset + rel
          end
          t_idx += 1 if (bits >> i) & 1 == 1
          cur += 1
        end
        # If all 7 bits processed and continuation bit clear, field is absent
        return nil if (b & 0x80) == 0
      end
    end

    private

    def read_schema(offset)
      key_count = @data.unpack1("@#{offset}S<")
      offset += 2

      @key_sigils = @data[offset, key_count].bytes
      offset += key_count

      # Null-terminated UTF-8 strings in StringPool
      pool = @data[offset..]
      pos  = 0
      key_count.times do |i|
        term = pool.index("\x00", pos)
        @keys << pool[pos...term].force_encoding("UTF-8")
        @key_index[@keys.last] = i
        pos = term + 1
      end
      offset += pos

      # Pad to 8-byte boundary
      rem = offset % 8
      offset += (8 - rem) % 8
      offset
    end

    MURMUR_C1 = 0xFF51AFD7ED558CCD
    MURMUR_C2 = 0xC4CEB9FE1A85EC53
    MURMUR_MASK = 0xFFFFFFFFFFFFFFFF

    def murmur3_64(bytes)
      h = 0x93681D6255313A99
      i = 0
      len = bytes.length
      while i < len
        chunk = bytes[i, 8]
        k = 0
        chunk.each_with_index { |b, j| k |= b << (j * 8) }
        k = (k * MURMUR_C1) & MURMUR_MASK
        k ^= k >> 33
        h ^= k
        h = (h * MURMUR_C2) & MURMUR_MASK
        h ^= h >> 33
        i += 8
      end
      h ^= len
      h ^= h >> 33
      h = (h * MURMUR_C1) & MURMUR_MASK
      h ^= h >> 33
      h
    end
  end

  # ── Object ───────────────────────────────────────────────────────────────────

  class Object
    def initialize(reader, offset)
      @reader = reader
      @offset = offset
      @parsed = false
    end

    def get_str(key)
      off = field_offset(key)
      return nil unless off
      len = @reader.data.unpack1("@#{off}L<")
      @reader.data[off + 4, len].force_encoding("UTF-8")
    end

    def get_i64(key)
      off = field_offset(key)
      return nil unless off
      @reader.data.unpack1("@#{off}q<")
    end

    def get_f64(key)
      off = field_offset(key)
      return nil unless off
      @reader.data.unpack1("@#{off}E")
    end

    def get_bool(key)
      off = field_offset(key)
      return nil unless off
      @reader.data.getbyte(off) != 0
    end

    private

    # Parse the object header (lazy — only on first field access).
    def parse_header
      return if @parsed
      p = @offset

      magic = @reader.data.unpack1("@#{p}L<")
      raise NxsError.new("ERR_BAD_MAGIC", "expected NXSO at #{p}") if magic != MAGIC_OBJ
      p += 8  # skip Magic(4) + Length(4)

      bitmask = []
      loop do
        b = @reader.data.getbyte(p)
        p += 1
        bitmask << (b & 0x7F)
        break if (b & 0x80) == 0
      end

      @bitmask          = bitmask
      @offset_tbl_start = p
      @parsed           = true
    end

    # Return the absolute byte offset of the field for `key`, or nil.
    def field_offset(key)
      slot = @reader.key_index[key]
      return nil unless slot

      # Delegate to Reader's scan logic (same implementation, avoids duplication)
      @reader._scan_offset(@reader.data, @offset, slot)
    end
  end
end
