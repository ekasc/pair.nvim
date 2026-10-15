if vim.g.loaded_pair_nvim then return end
vim.g.loaded_pair_nvim = true
require("pair").setup()
