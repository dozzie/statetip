#!/usr/bin/python

from setuptools import setup, find_packages
from glob import glob

setup(
    name         = "statetip",
    version      = "0.1.0",
    description  = "StateTip event stream registry client",
    scripts      = ["bin/statetip"],
    packages     = find_packages("pylib"),
    package_dir  = { "": "pylib" },
)
