#-----------------------------------------------------------------------------
#
# Sphinx configuration for StateTip project
#
#-----------------------------------------------------------------------------

project = u'StateTip'
#copyright = u'...'

release = '0.1.1'
version = '0.1'

#-----------------------------------------------------------------------------

# minimal Sphinx version
#needs_sphinx = '1.0'

extensions = ['sphinx.ext.autodoc', 'sphinx.ext.todo']

master_doc = 'index'
source_suffix = '.rst'
exclude_trees = ['html', 'man']

#-----------------------------------------------------------------------------
# configuration specific to Python code
#-----------------------------------------------------------------------------

import sys, os
sys.path.insert(0, os.path.abspath("../pylib"))

# ignored prefixes for module index sorting
#modindex_common_prefix = []

# documentation for constructors: docstring from class, constructor, or both
autoclass_content = 'both'

#-----------------------------------------------------------------------------
# HTML output
#-----------------------------------------------------------------------------

html_theme = 'poole'
html_theme_path = ['themes']

pygments_style = 'sphinx'

#html_static_path = ['static']

#-----------------------------------------------------------------------------
# TROFF/man output
#-----------------------------------------------------------------------------

man_pages = [
    ('manpages/client', 'statetip', 'StateTip client',
     [], 1),
    ('manpages/daemon', 'statetipd', 'StateTip daemon',
     [], 8),
    ('manpages/protocols', 'statetip-protocol',
     'StateTip communication protocol',
     [], 7),
]

#man_show_urls = False

#-----------------------------------------------------------------------------
# vim:ft=python
