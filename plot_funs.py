#!/usr/bin/env python

from __future__ import division

import locale

from collections import defaultdict, OrderedDict
from copy import copy
from fractions import Fraction
from glob import glob
import itertools
from math import sqrt
from os.path import basename
from sys import exit

import numpy as np
from colorsys import hsv_to_rgb
import matplotlib as mpl
mpl.use('pdf')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection

from graph_properties import vertexCounts
from names import Naming, names
from measurements import Measurement
from table import Table

def isGenerated(name):
    return (name.startswith("chain") or name.startswith("star")
         or name.startswith("degree") or name.startswith("mesh"))

def isWarp(name):
    return "warp" in name

locale.setlocale(locale.LC_NUMERIC, "")

params = {'legend.fontsize': 20 }
plt.rcParams.update(params)

def colours():
    def fractions(value):
        for v in [Fraction(8,10), Fraction(5,10)]:
            yield tuple(float(f) for f in hsv_to_rgb(value, Fraction(6,10), v))

    for c in fractions(0):
        yield c

    for i in (2**k for k in itertools.count()):
        for j in xrange(1,i,2):
            for c in fractions(Fraction(j,i)):
                yield c

class Plot(object):
    def __init__(self, filename):
        self.filename = filename
        self.handles = []
        self.labels = []

    def __enter__(self):
        self.fig, self.ax = plt.subplots(figsize=(16, 5), dpi=300)
        old_bar = self.ax.bar
        self.ax.extra_axes = OrderedDict()

        def replaceBar(fn):
            def newFn(*args, **kwargs):
                self.labels.append(kwargs['label'])
                del kwargs['label']
                result = fn(*args, **kwargs)
                self.handles.append(result)
                return result
            return newFn

        def replaceTwin(fn):
            def updateTwin(name):
                newAx = fn()
                self.ax.extra_axes[name] = newAx
                newAx.bar = replaceBar(newAx.bar)
                newAx.twinx = replaceTwin(newAx.twinx)
                newAx.twiny = replaceTwin(newAx.twiny)
                return newAx
            return updateTwin

        self.ax.bar = replaceBar(self.ax.bar)
        self.ax.twinx = replaceTwin(self.ax.twinx)
        self.ax.twiny = replaceTwin(self.ax.twiny)
        return self.ax

    def __exit__(self, exc_type, exc_value, tb):
        step = 1.0
        hs, ls = self.ax.get_legend_handles_labels()
        for name, ax in self.ax.extra_axes.items():
            h, l = ax.get_legend_handles_labels()
            hs += h
            ls += l

            ax.spines['right'].set_position(('axes', step))
            step += 0.1
            ax.set_frame_on(True)
            ax.patch.set_visible(False)

        legend = self.ax.legend(hs + self.handles, ls + self.labels,
                loc='upper center', bbox_to_anchor=(0.5,-0.1), markerscale=2,
                numpoints=1, scatterpoints=1, ncol=4)
        self.fig.savefig(self.filename + '.pdf', bbox_extra_artists=(legend,),
                         bbox_inches='tight')
        plt.close(self.fig)
        return None

def plotBars(ax, normalise, data, groupNames=Naming(), columnNames=Naming()):
    dims = data.dims()

    groups = sorted(data.keys(dim=dims[0]))
    numGroups = len(groups)

    columns = sorted(data.keys(dim=dims[1]))
    numBars = len(columns) + 1

    fun = lambda m: m.avg
    if normalise:
        for k in data:
            maxVal = max(data[k].values())
            data[k].map(lambda m: m.normalise(maxVal))

        fun = lambda m: m.normalised

    data = data.transform(fun)
    ind = np.arange(0, numBars * numGroups, numBars)

    for i, (column, colour) in enumerate(zip(columns, colours())):
        values = [data[group][column] for group in groups]

        ax.bar(ind + i, values, 1, color=colour, label=columnNames[column])

    fontsize=25
    if normalise:
        ax.set_ylabel('Normalised runtime', fontsize=fontsize)
    else:
        ax.set_ylabel('Runtime (ns)', fontsize=fontsize)

    ax.set_xticks(ind + (numBars // 3))
    ax.set_xticklabels([groupNames[n] for n in groups], fontsize=fontsize,
            rotation=-35, ha='left', va='top')
    ax.set_yticklabels(ax.get_yticklabels(), fontsize=fontsize)

    ySettings = {'ymin' : 0}
    if normalise:
        ySettings['ymax'] = 1

    ax.set_ylim(**ySettings)
    ax.set_xlim(xmin = 0, xmax = numBars * numGroups)

def plotPoints(ax, data, marks=('.',), dotNames=Naming(), crossProduct=False):
    if crossProduct:
        colouredMarks = ((c,m) for c in colours() for m in marks)
    else:
        colouredMarks = itertools.izip(colours(), itertools.cycle(marks))
    for k, (colour, mark) in zip(sorted(data), colouredMarks):
        ax.scatter(*zip(*data[k]), marker=mark, s=50, color=colour, label=k)

def plotLines(ax, data, lineNames=Naming(), independent=False):
    currAx = ax
    for k, c in zip(sorted(data), colours()):
        if independent:
            currAx = ax.twinx(k)
            currAx.set_yticks([])
            currAx.set_ylabel(k, color=c)
            currAx.tick_params(axis='y', colors=c)

        if isinstance(data[k], LineCollection):
            data[k].set(label=k, linewidth=2, color=c)
            currAx.add_collection(data[k])
        else:
            currAx.plot(*zip(*data[k]), label=k, linewidth=2, color=c)

def plotDataSet(dims, group, column, measurements, normalise):
    def plotHelper(data, order, fileName=''):
        if len(order) == 2:
            groupNames = names[order[0][0]]
            columnNames = names[order[1][0]]
            with Plot(fileName) as ax:
                plotBars(ax, normalise, data, groupNames, columnNames)
        elif order[0][1] == '':
            for k in data:
                if fileName:
                    newFile = fileName + '.' + k
                else:
                    newFile = k
                plotHelper(data[k], order[1:], fileName=newFile)
        else:
            data = data.collapseDim(order[0][0], order[0][1])
            plotHelper(data, order[1:], fileName=fileName)

    transpose = []
    defaults = []
    for i, (k, v) in enumerate(dims.items()):
        if k == group:
            group = (i, k)
        elif k == column:
            column = (i, k)
        elif v == '':
            transpose.append((i, k))
        else:
            defaults.append((i,k))

    transpose += defaults + [group, column]
    measurements = measurements.transposeDims(*[i for i, _ in transpose])

    plotHelper(measurements, [(k,dims[k]) for _, k in transpose])

def parseFiles(path, table, ext=".timings", process_line=None):
    if not path.endswith('/'):
        path += '/'

    if not ext.startswith('.'):
        ext = "." + ext

    def default_process_line(line, ns):
        ns["timer"], timings = line.strip().split(':')
        return (Measurement(timings), ns)

    namespace = dict()
    basedims = ["algorithm", "implementation", "device"]
    for input_file in glob(path + "*" + ext):
        split = basename(input_file)[:-len(ext)].split('.')
        if len(split) == 3:
            for k, v in zip(basedims, split):
                namespace[k] = v

            if process_line is None:
                def process_line(line, ns):
                    ns["graph"], ns["timer"], timings = line.strip().split(':')
                    split = ns["graph"].split('.')
                    if len(split) == 1:
                        ns["sorting"] = "normal"
                    else:
                        ns["graph"], ns["sorting"] = split
                    return (Measurement(timings), ns)

        elif len(split) == 4:
            for k, v in zip(["graph"] + basedims, split):
                namespace[k] = v

            namespace["sorting"] = "normal"

        elif len(split) == 5:
            for k, v in zip(["graph", "sorting"] + basedims, split):
                namespace[k] = v

        else:
            print "Ach mein leben!"
            print input_file
            exit(1)

        if process_line is None:
            process_line = default_process_line

        with open(input_file) as file:
            for line in file:
                result, ns = process_line(line, copy(namespace))
                table[tuple(ns[k] for k in table.dims())] = result

def plotPerformance(opts):
    data = loadData(Measurement, opts.dims, opts.paths, filters=opts.filters)
    plotDataSet(opts.dims, opts.group, opts.column, data, opts.normalise)

def setLabelOffset(data, step, axis):
    if axis == 'x':
        idx = 0
    elif axis == 'y':
        idx = 1
    else:
        raise Exception("Invalid axis.")

    i = step/2
    offset = dict()
    for label in sorted(set(v[idx] for l in data.values() for v in l)):
        offset[label] = i
        i += step

    for (label, coords) in data.items():
        data[label] = [v[:idx] + (offset[v[idx]],) + v[idx+1:] for v in coords]

    labels, ticks = zip(*sorted(offset.items(), key=lambda x: x[1]))
    return ticks, labels

def addColumnOffset(data, step, axis):
    if axis == 'x':
        idx = 0
    elif axis == 'y':
        idx = 1
    else:
        raise Exception("Invalid axis.")

    offset = dict()
    for i, graph in enumerate(sorted(data)):
        offset[graph] = i

    offRange = (0.75*step)/2
    off = offRange/len(offset)
    for k in offset:
        offset[k] *= off
        offset[k] -= offRange/2

    for (label, coords) in data.items():
        data[label] = [v[:idx] + (v[idx] + offset[label],) + v[idx+1:] for v in coords]

def indices(l, *ind):
    return [l.index(v) for v in ind]

def computeLines(data):
    for graph in data:
        newData = defaultdict(list)
        runningTotal = 0
        for s in data[graph]:
            data[graph][s] = sorted(data[graph][s])

        for depth, frontier in data[graph]['frontier']:
            newData['cumulative'] += [(depth, runningTotal)]
            runningTotal += frontier

        data[graph].update(newData)

def plotFrontier(opts):
    runtimeData = loadData(Measurement, opts.dims, opts.paths,
            filters=opts.filters)

    runtimeData = runtimeData.filterKeys(lambda k: not k.startswith("bfsLevel"), dim='timer')

    dims = [d for d in opts.dims if d != 'timer'] + ['depth']

    frontierData = loadData(int, dims, opts.paths, ext=".frontier",
            process_line=process_frontier_line, filters=opts.filters)
    visitedData = loadData(int, dims, opts.paths, ext=".visited",
            process_line=process_frontier_line, filters=opts.filters)

    lines = defaultdict(lambda: defaultdict(set))
    plotData = Table(list, "graph", "frontier", "implementation")
    for k, frontier in frontierData.sparseitems():
        depth = int(k[6][len("bfsLevel"):])
        plotData[k[3], depth, k[5] + "-" + k[0]] += [runtimeData[k]]
        lines[k[3]]['frontier'] |= set([(depth, frontier)])
        if k[5] == 'vertex-pull':
            lines[k[3]]['pull-visited'] |= set([(depth, visitedData[k])])
            lines[k[3]]['pull-visited-fraction'] |= set([(depth, frontier / visitedData[k])])
        else:
            lines[k[3]]['visited'] |= set([(depth, visitedData[k])])
            lines[k[3]]['visited-fraction'] |= set([(depth, frontier / visitedData[k])])

    computeLines(lines)
    plotData = plotData.transform(lambda x: stdDev(x)[1])

    for graph in plotData:
        points = defaultdict(list)
        for depth in plotData[graph]:
            for (impl,), runtime in plotData[graph, depth].sparseitems():
                points[impl] += [(depth, runtime)]

        with Plot(graph) as ax:
            #ticks, labels = setLabelOffset(points, 4, 'y')
            #addColumnOffset(points, 4, 'y')

            ms = ['o', 'v', '^', '<', '>', '8', 's', 'p', '*', 'h', 'H', '+', 'x', 'D', 'd']
            plotPoints(ax, points, marks=ms)
            #mirror = ax.twinx('Sizes')
            plotLines(ax, lines[graph], independent=True)
            for axis in ax.extra_axes.values():
                axis.autoscale()
                axis.set_yscale('linear')

            #mirror.autoscale()
            #mirror.set_yscale('log')

            ax.autoscale()
            ax.set_yscale('log')

measurementDims = OrderedDict()
measurementDims['paths'] = ''
measurementDims['device'] = ''
measurementDims['algorithm'] = ''
measurementDims['graph'] = ''
measurementDims['sorting'] = 'normal'
measurementDims['implementation'] = ''
measurementDims['timer'] = 'computation'

def loadData(default, dims, paths, ext=".timings", process_line=None, filters=dict()):
    data = Table(default, *dims)
    for path in paths:
        path = path.rstrip('/')
        parseFiles(path, data[path], ext=ext, process_line=process_line)

    for dim in set(filters).intersection(data.dims()):
        data = data.filterKeys(filters[dim], dim=dim)

    return data

def process_frontier_line(line, ns):
    depth, frontier = line.strip().split('\t')
    ns["depth"] = "bfsLevel" + str(depth)
    return (int(frontier.replace(',', '')), ns)

def stdDev(l):
    if isinstance(l[0], Measurement):
        l = map(lambda x: x.avg, l)

    minimum = min(l)
    maximum = max(l)
    total = sum(l)
    avg = total/len(l)
    stddev = 0
    for t in l:
        stddev += (t - avg) ** 2

    if len(l) > 1:
        stddev *= 1.0 / (len(l) - 1)
        stddev = sqrt(stddev)
    else:
        stddev = 0

    return (minimum, avg, maximum, stddev)
