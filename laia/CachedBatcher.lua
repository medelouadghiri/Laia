require 'image'

local CachedBatcher = torch.class('laia.CachedBatcher')

function CachedBatcher:__init(opt)
  self._opt = {
    centered_patch = true,
    cache_max_size = 512,
    cache_gpu      = 0,
    invert_colors  = true,
    min_width      = 0,
    width_factor   = 0
  }
  -- Set batcher options
  self:setOptions(opt)
  -- Initialize internal variables
  self:clearDataset()
end

function CachedBatcher:registerOptions(parser)
  parser:option(
    '--batcher_center_patch',
    'If true, place all the image patches at the center of the batch. ' ..
      'Otherwise, the images are aligned at the (0,0) corner. Images in a ' ..
      'batch are always zero-padded to have the same size.',
    true, laia.toboolean)
    :argname('<bool>')
    :overwrite(false)
    :bind(self._opt, 'centered_patch')
  parser:option(
    '--batcher_cache_max_size',
    'Use a cache of this size (MB) to preload the images. (Note: If you ' ..
      'have enough memory, try to load the whole dataset once to avoid ' ..
      'repeatedly access to the disk).', 512, laia.toint)
    :argname('<size>')
    :overwrite(false)
    :bind(self._opt, 'cache_max_size')
  parser:option(
    '--batcher_cache_gpu',
    'Use this GPU (GPU index starting from 1, 0 for CPU) to cache the ' ..
      'images. Unless you have GPU with an humongous amount of memory, you ' ..
      'want to leave this to 0 (CPU).',
      0, laia.toint)
    :argname('<gpu>')
    :overwrite(false)
    :bind(self._opt, 'cache_gpu')
  parser:option(
    '--batcher_min_width',
    'Minimum image width. Images with a width lower than this value are ' ..
      'zero-padded.', 0, laia.toint)
    :argname('<width>')
    :overwrite(false)
    :bind(self._opt, 'min_width')
  -- TODO(mauvilsa): The current implementation assumes that the pixel values
  -- must be inverted.
  -- cmd:option('-batcher_invert', true, 'Invert the image pixel values')
end

function CachedBatcher:setOptions(opt)
  if opt then table.update_values(self._opt, opt) end
  self:checkOptions()
end

function CachedBatcher:checkOptions()
  assert(laia.isint(self._opt.cache_max_size) and self._opt.cache_max_size > 0)
  assert(laia.isint(self._opt.cache_gpu))
  assert(laia.isint(self._opt.min_width) and self._opt.min_width >= 0)
  assert(laia.isint(self._opt.width_factor))
  -- TODO(mauvilsa): The current implementation assumes that the pixel values
  -- must be inverted.
  assert(self._opt.invert_colors == true)
end

function CachedBatcher:numSymbols()
  return self._num_symbols
end

function CachedBatcher:numSamples()
  return self._num_samples
end

function CachedBatcher:numChannels()
  return self._channels
end

function CachedBatcher:cacheType()
  -- Note: GPU index starts at 1, <= 0 is used for the CPU
  return self._cache_gpu > 0 and 'torch.CudaTensor' or 'torch.FloatTensor'
end

function CachedBatcher:clearCache()
  self._cache_img = {}
  self._cache_gt = {}
  self._cache_idx = 0
  self._cache_size = 0
  collectgarbage()
end

function CachedBatcher:clearDataset()
  self._num_samples = 0
  self._samples = {}
  self._imglist = {}
  self._gt = {}
  self._has_gt = false
  self._num_symbols = 0
  self._sym2int = {}
  self._int2sym = {}
  self._idx = 0
  self._channels = nil
  self:clearCache()
end

function CachedBatcher:load(img_list, gt_file, symbols_table)
  self:clearDataset()
  self._has_gt = gt_file and true or false

  -- Load sample transcripts
  if self._has_gt then
    -- Load symbols list
    assert(symbols_table ~= nil,
	   'A symbols list is required when providing transcripts')
    local f = io.open(symbols_table, 'r')
    assert(f ~= nil, ('Unable to read symbols file: %q'):format(symbols_table))
    local ln = 0
    while true do
      local line = f:read('*line')
      if line == nil then break end
      ln = ln + 1
      local sym, id = string.match(line, '^(%S+)%s+(%d+)$')
      assert(sym ~= nil and id ~= nil,
	     ('Expected a string and an integer separated by a space at ' ..
		'line %d in file %q'):format(ln, symbols_table))
      self._sym2int[sym] = tonumber(id)
      table.insert(self._int2sym, tonumber(id), sym)
      self._num_symbols = tonumber(id) > self._num_symbols and tonumber(id) or
	self._num_symbols
    end
    f:close()

    -- Load sample transcripts
    local f = io.open(gt_file, 'r')
    assert(f ~= nil, ('Unable to read transcripts file: %q'):format(gt_file))
    local ln = 0
    while true do
      local line = f:read('*line')
      if line == nil then break end
      ln = ln + 1
      local id, txt = string.match(line, '^(%S+)%s+(%S.*)$')
      assert(id ~= nil and txt ~= nil,
	     ('Wrong transcript format at line %d in file %q'):format(ln,
								      gt_file))
      self._gt[id] = {}
      for sym in txt:gmatch('%S+') do
        assert(self._sym2int[sym] ~= nil,
	       ('Symbol %q is not in the symbols table'):format(sym))
        table.insert(self._gt[id], self._sym2int[sym])
      end
    end
    f:close()
  end

  -- Load image list and sample IDs. By default, they are ordered as read from
  -- the list. The IDs are the basenames of the files, i.e., removing directory
  -- and extension.
  local f = io.open(img_list, 'r')
  assert(f ~= nil, ('Unable to read image list file: %q'):format(img_file))
  local ln = 0
  while true do
    local line = f:read('*line')
    if line == nil then break end
    ln = ln + 1
    local id = string.match( string.gsub(line, ".*/", ""), '^(.+)[.][^./]+$' )
    assert(id ~= nil, ('Unable to determine sample ID at line %d in ' ..
			 'file %q'):format(ln, img_list))
    assert(not self._has_gt or self._gt[id] ~= nil,
	   ('No transcript found for sample %q'):format(id))
    table.insert(self._imglist, line)
    table.insert(self._samples, id)
    self._num_samples = self._num_samples + 1
  end
  f:close()
end

function CachedBatcher:epochReset(epoch_opt)
  -- This should be override by children classes.
end

function CachedBatcher:next(batch_size, batch_img)
  batch_size = batch_size or 1
  batch_img  = batch_img or torch.FloatTensor()
  local batch_gt   = {}
  local batch_ids  = {}
  local batch_hpad = {}
  assert(batch_size > 0, 'Batch size must be greater than 0!')
  assert(self._num_samples > 0, 'The dataset is empty!')
  -- Get sizes of each sample in the batch
  local batch_sizes = torch.LongTensor(batch_size, 2)
  for i=0,(batch_size-1) do
    local j = 1 + (i + self._idx) % self._num_samples
    self:_fillCache(j)
    local cacheIdx = self:_global2cacheIndex(j)
    local img = self._cache_img[cacheIdx]
    batch_sizes[{i+1,1}] = img:size(2)     -- Image height
    batch_sizes[{i+1,2}] = img:size(3)     -- Image width
  end
  -- Copy data into single batch tensors
  local max_sizes = torch.max(batch_sizes, 1)
  max_sizes[{1,2}] = math.max(max_sizes[{1,2}], self._opt.min_width)
  if self._opt.width_factor > 0 then
    max_sizes[{1,2}] = self._opt.width_factor *
      math.ceil(max_sizes[{1,2}] / self._opt.width_factor)
  end
  batch_img:resize(batch_size, self._channels,
		   max_sizes[{1,1}], max_sizes[{1,2}]):zero()
  local old_gpu = -1
  if self._opt.cache_gpu > 0 then
    old_gpu = cutorch.getDevice()
    cutorch.setDevice(self._opt.cache_gpu - 1)
    batch_img = batch_img:cuda()
  end
  for i=0,(batch_size-1) do
    local j = 1 + (i + self._idx) % self._num_samples
    self:_fillCache(j)
    local img = self._cache_img[self:_global2cacheIndex(j)]
    local gt  = self._cache_gt[self:_global2cacheIndex(j)]
    local dy = 0
    local dx = 0
    if self._centered_patch then
      dy = math.floor((max_sizes[{1,1}] - img:size(2)) / 2)
      dx = math.floor((max_sizes[{1,2}] - img:size(3)) / 2)
    end
    batch_img[i+1]:sub(1, self._channels,
		       dy + 1, dy + img:size(2),
		       dx + 1, dx + img:size(3)):copy(img)
    table.insert(batch_gt, gt)
    table.insert(batch_ids, self._samples[j])
    table.insert(batch_hpad, {dx,img:size(3),max_sizes[{1,2}]-dx-img:size(3)})
  end
  if old_gpu >= 0 then
    cutorch.setDevice(old_gpu)
  end
  -- Increase index for next batch
  self._idx = (self._idx + batch_size) % self._num_samples
  collectgarbage()
  return batch_img, batch_gt, batch_sizes, batch_ids, batch_hpad
end

function CachedBatcher:_global2cacheIndex(idx)
  if #self._cache_img < 1 then return -1 end
  if idx < 1 or idx > self._num_samples then return -1 end
  idx = idx - 1
  local cacheEnd = (self._cache_idx + #self._cache_img) % self._num_samples
  if self._cache_idx < cacheEnd then
    -- Cache is contiguous: [i, i+1, ..., i + M]
    if idx >= self._cache_idx and idx < cacheEnd then
      return 1 + idx - self._cache_idx
    else
      return -1
    end
  else
    -- The cache is circular: [i, i + 1, ..., i + N, 0, ..., M - N - 1]
    if idx >= self._cache_idx or idx < cacheEnd then
      return 1 + (idx - self._cache_idx) % self._num_samples
    else
      return -1
    end
  end
end

function CachedBatcher:_cache2globalIndex(idx)
  if idx < 1 or idx > #self._cache_img then return -1 end
  return 1 + (self._cache_idx + idx - 1) % self._num_samples
end

function CachedBatcher:_fillCache(idx)
  -- If the requested image is not available in the cache, fill the cache
  -- with it and all the following images until the cache size increases up to
  -- self._opt.cache_max_size MB (approx)
  if self:_global2cacheIndex(idx) < 0 then
    idx = idx - 1
    self._cache_img = {}
    self._cache_size = 0
    self._cache_idx = idx  -- First cached image = first in the batch
    -- Allocate memory in the GPU device self._opt.cache_gpu, the current device
    -- is saved and restored later.
    local old_gpu = -1
    if self._opt.cache_gpu > 0 then
      old_gpu = cutorch.getDevice()
      cutorch.setDevice(self._opt.cache_gpu - 1)
    end
    while self._cache_size < self._opt.cache_max_size and
    #self._cache_img < self._num_samples do
      local j = 1 + (#self._cache_img + idx) % self._num_samples
      -- Load image from disk, and try to convert it to use the number of
      -- channels of the batcher. If the number of channels have not been set,
      -- use the image channels.
      local img = image.load(self._imglist[j], self._channels):float()
      self._channels = self._channels or img:size(1)
      -- Invert colors
      img:apply(function(v) return 1.0 - v end)
      -- Store data in the GPU, if requested.
      if self._opt.cache_gpu > 0 then
	table.insert(self._cache_img, img:cuda())
      else
	table.insert(self._cache_img, img:float())
      end
      -- Increase size of the cache (in MB)
      self._cache_size = self._cache_size +
	img:nElement() * img:storage():elementSize() / 1048576
    end
    -- Restore value of the current GPU device
    if old_gpu >= 0 then
      cutorch.setDevice(old_gpu)
    end
  end
end

return CachedBatcher
