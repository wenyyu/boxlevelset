import mmcv
import numpy as np
from numpy import random
from mmdet.core import poly2bbox
from mmdet.core.evaluation.bbox_overlaps import bbox_overlaps
from pycocotools.coco import maskUtils
import cv2
from functools import partial
import copy

global_idx = 0

def TuplePoly2Poly(poly):
    outpoly = [poly[0][0], poly[0][1],
               poly[1][0], poly[1][1],
               poly[2][0], poly[2][1],
               poly[3][0], poly[3][1]
               ]
    return outpoly


# def mask2poly_single(binary_mask):
#     """
#     :param binary_mask:
#     :return:
#     """
#     # try:
#     contours, hierarchy = cv2.findContours(binary_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
#     # print('contours', contours)
#     max_contour = max(contours, key=len)
#     rect = cv2.minAreaRect(max_contour)
#     poly = cv2.boxPoints(rect)
#     # print('')
#     poly = TuplePoly2Poly(poly)
#     # print('poly', poly)
#
#     return poly


def mask2poly_single(binary_mask):
    """

    :param binary_mask:
    :return:
    """
    # try:
    contours, hierarchy = cv2.findContours(binary_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    # print('contours', contours)
    if len(contours) > 0:
        max_contour = max(contours, key=len)
        rect = cv2.minAreaRect(max_contour)
        poly = cv2.boxPoints(rect)
        # print('')
        poly = TuplePoly2Poly(poly)
    else:
        poly = [0.01, 0.011, 0.02, 0.012, 0.021, 0.023, 0.013, 0.02]
    # print('poly######################', poly)
    return poly


def mask2poly(binary_mask_list):
    polys = map(mask2poly_single, binary_mask_list)
    return list(polys)


def poly2mask_single(h, w, poly):
    # TODO: write test for poly2mask, using mask2poly convert mask to poly', compare poly with poly'
    # visualize the mask
    rles = maskUtils.frPyObjects(poly, h, w)
    rle = maskUtils.merge(rles)
    mask = maskUtils.decode(rle)

    return mask


def poly2mask(polys, h, w):
    poly2mask_fn = partial(poly2mask_single, h, w)
    masks = list(map(poly2mask_fn, polys))
    # TODO: check if len(masks) == 0
    return masks


def rotate_poly_single(h, w, new_h, new_w, rotate_matrix_T, poly):
    poly[::2] = poly[::2] - (w - 1) * 0.5
    poly[1::2] = poly[1::2] - (h - 1) * 0.5
    coords = poly.reshape(4, 2)
    new_coords = np.matmul(coords, rotate_matrix_T) + np.array([(new_w - 1) * 0.5, (new_h - 1) * 0.5])
    rotated_polys = new_coords.reshape(-1, ).tolist()

    return rotated_polys


# TODO: refactor the single - map to whole numpy computation
def rotate_poly(h, w, new_h, new_w, rotate_matrix_T, polys):
    rotate_poly_fn = partial(rotate_poly_single, h, w, new_h, new_w, rotate_matrix_T)
    rotated_polys = list(map(rotate_poly_fn, polys))

    return rotated_polys


class RotateAugmentation(object):
    """
    1. rotate image and polygons, transfer polygons to masks
    2. polygon 2 mask
    """

    def __init__(self,
                 # center=None,
                 CLASSES=None,
                 scale=1.0,
                 border_value=0,
                 auto_bound=True,
                 rotate_range=(-180, 180),
                 rotate_ratio=1.0,
                 rotate_values=[0, 45, 90, 135, 180, 225, 270, 315],
                 rotate_mode='range',
                 small_filter=4):
        self.CLASSES = CLASSES
        self.scale = scale
        self.border_value = border_value
        self.auto_bound = auto_bound
        self.rotate_range = rotate_range
        self.rotate_ratio = rotate_ratio
        self.rotate_values = rotate_values
        self.rotate_mode = rotate_mode
        self.small_filter = small_filter
        # self.center = center

    def __call__(self, img, boxes, masks, labels, filename):
        # whether to rotate
        global global_idx

        if np.random.rand() > self.rotate_ratio:
            angle = 0.0
        else:
            if self.rotate_mode == 'range':
                angle = np.random.rand() * (self.rotate_range[1] - self.rotate_range[0]) + self.rotate_range[0]
                discrete_range = [90, 180, -90, -180]
                for label in labels:
                    cls = self.CLASSES[label - 1]
                    if (cls == 'storage-tank') or (cls == 'storage_tank') or (cls == 'roundabout') or (cls == 'Roundabout') or (cls == 'airport'):
                        random.shuffle(discrete_range)
                        angle = discrete_range[0]
                        break
            elif self.rotate_mode == 'value':
                random.shuffle(self.rotate_values)
                angle = self.rotate_values[0]

        # rotate image, copy from mmcv.imrotate
        h, w = img.shape[:2]
        center = ((w - 1) * 0.5, (h - 1) * 0.5)
        matrix = cv2.getRotationMatrix2D(center, -angle, self.scale)
        matrix_T = copy.deepcopy(matrix[:2, :2]).T
        if self.auto_bound:
            cos = np.abs(matrix[0, 0])
            sin = np.abs(matrix[0, 1])
            new_w = h * sin + w * cos
            new_h = h * cos + w * sin
            matrix[0, 2] += (new_w - w) * 0.5
            matrix[1, 2] += (new_h - h) * 0.5
            w = int(np.round(new_w))
            h = int(np.round(new_h))
        rotated_img = cv2.warpAffine(img, matrix, (w, h), borderValue=self.border_value)
        polys = mask2poly(masks)

        rotated_polys = rotate_poly(img.shape[0], img.shape[1], h, w, matrix_T, np.array(polys))

        rotated_polys_np = np.array(rotated_polys)
        # add dimension in poly2mask
        rotated_masks = poly2mask(rotated_polys_np[:, np.newaxis, :].tolist(), h, w)
        rotated_boxes = poly2bbox(rotated_polys_np).astype(np.float32)

        # True rotated h, sqrt((x1-x2)^2 + (y1-y2)^2)
        rotated_h = np.sqrt(np.power(rotated_polys_np[:, 0] - rotated_polys_np[:, 2], 2)
                            + np.power(rotated_polys_np[:, 1] - rotated_polys_np[:, 3], 2))
        # True rotated w, sqrt((x2 - x3)^2 + (y2 - y3)^2)
        rotated_w = np.sqrt(np.power(rotated_polys_np[:, 2] - rotated_polys_np[:, 4], 2)
                            + np.power(rotated_polys_np[:, 3] - rotated_polys_np[:, 5], 2))
        min_w_h = np.minimum(rotated_h, rotated_w)
        keep_inds = (min_w_h * img.shape[0] / np.float32(h)) >= self.small_filter

        if len(keep_inds) > 0:
            rotated_boxes = rotated_boxes[keep_inds].tolist()
            rotated_masks = np.array(rotated_masks)[keep_inds]
            labels = labels[keep_inds]

        else:
            rotated_boxes = np.zeros((0, 4), dtype=np.float32).tolist()
            rotated_masks = []
            labels = np.array([], dtype=np.int64)

        return rotated_img, rotated_boxes, rotated_masks, labels


class RotateTestAugmentation(object):
    """
    rotate image give a specific angle
    """

    def __init__(self,
                 scale=1.0,
                 border_value=0,
                 auto_bound=True):
        self.scale = scale
        self.border_value = border_value
        self.auto_bound = auto_bound
        # self.center = center

    def __call__(self, img, angle=None):
        """
        :param angle: the angle is in degeree
        :return:
        """
        assert angle in [90, 180, 270]
        # rotate image, copy from mmcv.imrotate
        h, w = img.shape[:2]
        center = ((w - 1) * 0.5, (h - 1) * 0.5)
        matrix = cv2.getRotationMatrix2D(center, -angle, self.scale)
        if self.auto_bound:
            cos = np.abs(matrix[0, 0])
            sin = np.abs(matrix[0, 1])
            new_w = h * sin + w * cos
            new_h = h * cos + w * sin
            matrix[0, 2] += (new_w - w) * 0.5
            matrix[1, 2] += (new_h - h) * 0.5
            w = int(np.round(new_w))
            h = int(np.round(new_h))
        rotated_img = cv2.warpAffine(img, matrix, (w, h), borderValue=self.border_value)
        rotated_img_shape = rotated_img.shape

        return rotated_img, rotated_img_shape, rotated_img_shape, self.scale
