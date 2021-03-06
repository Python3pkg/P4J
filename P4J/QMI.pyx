#!/usr/bin/python
#cython: initializedcheck=False, boundscheck=False, wraparound=False, cdivision=True, profile=False

cimport cython
#import numpy as np
#from numpy cimport ndarray, double_t, int_t
#from libc.math cimport sqrt, pow, M_PI, log
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from scipy.special.cython_special cimport i0

#DTYPE = np.double
ctypedef float DTYPE_t
#ctypedef int_t ITYPE_t

cdef extern from "math.h":
    DTYPE_t cosf(DTYPE_t)
    DTYPE_t fabsf(DTYPE_t)
    DTYPE_t sqrtf(DTYPE_t)
    DTYPE_t powf(DTYPE_t, DTYPE_t)
    DTYPE_t logf(DTYPE_t)
    DTYPE_t expf(DTYPE_t)
    DTYPE_t remainderf(DTYPE_t, DTYPE_t)

cdef DTYPE_t M_PI = 3.1415926535897

"""
Fills the Information Potential matrix using a VonMises kernel
"""
cdef inline void IP_vonmises(DTYPE_t* IP, DTYPE_t* angle, DTYPE_t h_KDE, Py_ssize_t N):
    cdef Py_ssize_t i, j
    cdef DTYPE_t kappa = 1.0/powf(2.0*M_PI*h_KDE, 2.0)
    cdef DTYPE_t denominator = 2.0*M_PI*i0(kappa)
    for i in range(N):
        IP[indexMatrixToVector(i, i, N)] = expf(kappa)/denominator
        for j in range(i+1, N):
            IP[indexMatrixToVector(i, j, N)] = expf(kappa*cosf(angle[i] - angle[j]))/denominator
 
"""
Fills the Information Potential matrix using a Gaussian kernel
"""
cdef inline void IP_gaussian(DTYPE_t* IP, DTYPE_t [::1] data, DTYPE_t [::1] h_data, DTYPE_t h_KDE, Py_ssize_t N):
    cdef Py_ssize_t i, j
    cdef DTYPE_t gauss_var, delta2, h_KDE2 = 2.0*powf(h_KDE, 2.0)
    cdef DTYPE_t* h_data2 = <DTYPE_t*>PyMem_Malloc(N*sizeof(DTYPE_t))
    for i in range(N):
        h_data2[i] = powf(h_data[i], 2.0)
    for i in range(N):
        gauss_var = h_KDE2 + 2.0*h_data2[i]
        IP[indexMatrixToVector(i, i, N)] = 1.0/sqrtf(2.0*M_PI*gauss_var)
        for j in range(i+1, N):
            delta2 = powf(data[i] - data[j], 2.0)
            #delta2 = fabsf(data[i] - data[j])
            gauss_var = h_KDE2 + h_data2[i] + h_data2[j]
            IP[indexMatrixToVector(i, j, N)] = expf(-0.5*delta2/gauss_var)/sqrtf(2.0*M_PI*gauss_var)
    PyMem_Free(h_data2)


cdef Py_ssize_t indexMatrixToVector(Py_ssize_t i, Py_ssize_t j, Py_ssize_t N):
    # Only works for i <= j, which is always the case here
    return i*N - (i-1)*i/2 + j - i

cdef class QMI:
    cdef DTYPE_t* IP_M
    cdef DTYPE_t* IP_P
    cdef Py_ssize_t N
    cdef DTYPE_t* VC1
    cdef DTYPE_t* VC2
    cdef DTYPE_t VM1
    cdef DTYPE_t h_KDE_P
    cdef DTYPE_t* angle
    cdef DTYPE_t* mjd
    def __init__(self, DTYPE_t [::1] mjd, DTYPE_t [::1] mag, DTYPE_t [::1] err, DTYPE_t h_KDE_M, DTYPE_t h_KDE_P):
        cdef Py_ssize_t i, j, mat_idx
        self.N = mag.shape[0]
        self.mjd = <DTYPE_t*>PyMem_Malloc(self.N*sizeof(DTYPE_t))
        self.angle = <DTYPE_t*>PyMem_Malloc(self.N*sizeof(DTYPE_t))
        if not self.mjd:
            raise MemoryError()
        if not self.angle:
            raise MemoryError()
        for i in range(self.N):
            self.mjd[i] = mjd[i]
        #self.h_KDE_P = 0.9*(1.0/sqrtf(12.0))*powf(self.N, -0.2)  # bandwidth considering a uniform distribution in phase
        self.h_KDE_P = h_KDE_P
        self.IP_M = <DTYPE_t*>PyMem_Malloc(self.N*(self.N+1)/2*sizeof(DTYPE_t))
        self.IP_P = <DTYPE_t*>PyMem_Malloc(self.N*(self.N+1)/2*sizeof(DTYPE_t))
        if not self.IP_M:
            raise MemoryError()
        if not self.IP_P:
            raise MemoryError()
        IP_gaussian(self.IP_M, mag, err, h_KDE_M, self.N)
        self.VC1 = <DTYPE_t*>PyMem_Malloc(self.N*sizeof(DTYPE_t))
        self.VC2 = <DTYPE_t*>PyMem_Malloc(self.N*sizeof(DTYPE_t))
        if not self.VC1:
            raise MemoryError()
        if not self.VC2:
            raise MemoryError()
        self.VM1 = 0.0
        for i in range(self.N):
            self.VC1[i] = 0.0
        for i in range(self.N):
            mat_idx = indexMatrixToVector(i, i, self.N)
            self.VC1[i] += self.IP_M[mat_idx]
            self.VM1 += self.IP_M[mat_idx]
            for j in range(i+1, self.N):
                mat_idx = indexMatrixToVector(i, j, self.N)
                self.VC1[i] += self.IP_M[mat_idx]
                self.VC1[j] += self.IP_M[mat_idx]
                self.VM1 += 2.0*self.IP_M[mat_idx]

    def eval_frequency(self, DTYPE_t freq):
        cdef Py_ssize_t i, j
        for i in range(self.N):
            self.angle[i] = 2.0*M_PI*remainderf(self.mjd[i], 1.0/freq)*freq  # output in [-pi, pi]
        IP_vonmises(self.IP_P, self.angle, self.h_KDE_P, self.N)
        cdef Py_ssize_t mat_idx
        cdef DTYPE_t VM1=0.0, VM2=0.0, VC=0.0, VJ=0.0
        for i in range(self.N):
            self.VC2[i] = 0.0    
        for i in range(self.N):
            mat_idx = indexMatrixToVector(i, i, self.N)
            self.VC2[i] += self.IP_P[mat_idx]
            VM2 += self.IP_P[mat_idx]
            VJ += self.IP_M[mat_idx]*self.IP_P[mat_idx]
            for j in range(i+1, self.N):
                mat_idx = indexMatrixToVector(i, j, self.N)
                VM2 += 2.0*self.IP_P[mat_idx]
                self.VC2[j] += self.IP_P[mat_idx]
                self.VC2[i] += self.IP_P[mat_idx]
                VJ += 2.0*self.IP_M[mat_idx]*self.IP_P[mat_idx]
        for i in range(self.N):
            VC += self.VC1[i]*self.VC2[i]
        # Note that I omitted the log(N) terms because they cancel out in this sum
        return logf(self.VM1*VM2) + logf(VJ) - 2.0*logf(VC)

    def __dealloc__(self):
        PyMem_Free(self.IP_M)
        PyMem_Free(self.IP_P)
        PyMem_Free(self.mjd)
        PyMem_Free(self.angle)
        PyMem_Free(self.VC1)
        PyMem_Free(self.VC2)


